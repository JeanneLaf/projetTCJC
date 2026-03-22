### A Pluto.jl notebook ###
# v0.20.24

#> [frontmatter]
#> image = "https://cdn-icons-png.flaticon.com/512/4565/4565023.png"
#> language = "fr-CA"
#> title = "Proposition de modification au TCJC"
#> date = "2026-03-11"
#> 
#>     [[frontmatter.author]]
#>     name = "Jeanne Laflamme"

using Markdown
using InteractiveUtils

# ╔═╡ 43eb24bf-4357-4a51-ab12-a2fd000b9cf1
begin
using OpenStreetMapX, Dates, PyCall, Printf, DataFrames,PrettyTables, JSON3, HTTP,HypertextLiteral,PlutoUI, CSV

###################
#CARTE DE LA RÉGION
###################
mx = get_map_data("../maps/SCJC.pbf", use_cache=false,only_intersections=false);

###########################################
# Récupération des arrêts du RTC et du TCJC
###########################################
TCJC = Dict()
RTC = Dict()

open("../json/StopsTCJC.json", "r") do io 
	stopsTCJC = JSON3.read(io)[:stops] 
	for stop in stopsTCJC TCJC[stop[:stop_code]] = stop end
end
    
open("../json/StopsRTC.json", "r") do io 
	stopsRTC = JSON3.read(io)[:stops] 
	for stop in stopsRTC RTC[stop[:stop_code]] = stop end
end	

function get_node(mx::MapData,stop)
    lla_ref = LLA( 46.8230027 , -71.4947808)
    lla = LLA(stop[:stop_lat],stop[:stop_lon])
    return nearest_node(mx.nodes,ENU(lla,mx.bounds))
end

####################
# FONCTIONS
####################
function callAPI(depart::Tuple{Float64,Float64}, arrivee::Tuple{Float64,Float64}, heure::String)
	"""query = Dict(
		:from => (:coordinates => (:latitude => depart[1], :longitude => depart[2])),
		:to => (:coordinates => (:latitude => arrivee[1], :longitude => arrivee[2])),
		:dateTime => "2026-04-06T"*Dates.format(Time(heure),"HH:MM:SS")*"-04:00"
	)"""

	query= """
		query {
		  plan(
		    from: {lat: $(depart[1]), lon: $(depart[2])},
		    to: {lat: $(arrivee[1]), lon: $(arrivee[2])},
		    date: "2026-04-01",
			time: "$(heure)"
		  ) {
		    itineraries {
		      duration
		      startTime
		      endTime
		      legs {
		        mode
		        duration
		        legGeometry {
		          points
		        }
				startTime
				endTime
		        route {
		          gtfsId      # The unique route ID
		          shortName   # e.g., "801"
		          longName    # e.g., "Metrobus 800-801"
		          color       # e.g., "FF0000"
		          textColor   # The color for text displayed on the route color
		        }
				
		      }
		    }
		  }
		}
		"""
	# 3. Wrap the string in a JSON object under the key "query"
	body = JSON3.write(Dict("query" => query))

	# 4. Use HTTP.post with the correct headers
	headers = ["Content-Type" => "application/json"]
	
	response = HTTP.post("http://localhost:8080/otp/routers/default/index/graphql",headers,body);
	try
		return JSON3.read(response.body)[:data][:plan][:itineraries][1]
	catch e
		return 0
	end
end
	
function parse_itinerary(itinerary::JSON3.Object; MAP_BOUNDS=[(46.75,-71.5),(46.96,-71.4)])
	flm = pyimport("folium")
	polyline= pyimport("polyline")
	
	legs = itinerary[:legs]
	m = flm.Map()

	# Durée total du trajet
	hours, seconds = divrem(itinerary[:duration],3600)
	minutes,_ = divrem(seconds,60)
	duration = hours > 0 ? repr(hours)*"h"*repr(minutes) : repr(minutes)*" minutes" 

	#String contenant le trajet
	s = ""
	for leg in legs
		path_coordinates = polyline.decode(leg[:legGeometry][:points])
		if leg[:mode]=="WALK"
			if leg[:duration]>=60
				min = string(Int(round(leg[:duration] / 60)))
				text= "Marche "*min*" minutes"
				s*="- "*text*"\n"
				flm.PolyLine(        
				    locations=path_coordinates,
				    popup=text,
					weight=5,
					dash_array="1, 10",
				    color="blue"
				).add_to(m)
			else continue end
		else
			dt = unix2datetime(leg[:startTime]/1000 - 14400)
			display_time = Dates.format(dt, "HH:MM")

			dt_end = unix2datetime(leg[:endTime]/1000 - 14400)
			display_time_end = Dates.format(dt_end, "HH:MM")
			
			text = "Bus "*leg[:route][:shortName]*": "*display_time*"-"*display_time_end*"\n"
			s*="- "*text
			flm.PolyLine(        
			    locations=path_coordinates,
			    popup=text,
				weight=5,
			    color="#"*leg[:route][:color]
			).add_to(m)
		end
	end
	
	m.fit_bounds(MAP_BOUNDS)

	# Heure de départ
	dt = unix2datetime(itinerary[:startTime]/1000 - 14400) #time zone
	start_time = Dates.format(dt, "HH:MM")
	
	# Heure d'arrivée
	dt = unix2datetime(itinerary[:endTime]/1000 - 14400) #time zone
	end_time = Dates.format(dt, "HH:MM")
	
	return Dict(:map => m, :text => s, :duree => duration, :h_depart => start_time, :h_arrivee => end_time)
end

function compute_route(mx::MapData,parcours::Array)
    """
    Computes the time and distance between stops
    """
    all_route = []
    time_from_start=[Dates.Second(0)]
    distance_from_start=[0.0]
    total_distance = 0
    total_time = 0

    for i in 2:length(parcours)
        total_time+= 30 # Stop time
        route, distance, route_time = fastest_route(mx,get_node(mx,parcours[i-1]),get_node(mx,parcours[i]))
        all_route=vcat(all_route,route)
        total_distance += distance; push!(distance_from_start, total_distance)
        total_time += route_time; push!(time_from_start, Second(round(total_time))) 
    end  

    return Dict(:all_route => all_route, 
                :time_from_start => time_from_start,
                :total_distance => total_distance, 
                :total_time => total_time)
end

function compute_trip(route::Dict, start_time::Dates.Time, tf::Float64; reverse_direction=false)
    if reverse_direction
        end_time = route[:time_from_start][end]
        time_from_end = [end_time-t for t in route[:time_from_start]]
        reverse!(time_from_end)
        return [Dates.format(start_time + Second(floor(Dates.value(t)*tf)),"HH:MM:SS") 
                for t in time_from_end];
    else
        return [Dates.format(start_time + Second(floor(Dates.value(t)*tf)),"HH:MM:SS") 
                for t in route[:time_from_start]]
    end
end

#################
#ARRÊTS DU RÉSEAU
#################

all_stops = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],
             TCJC["10-03"],TCJC["10-02"],TCJC["10-01"],TCJC["30-04"],TCJC["30-03"],
             TCJC["30-02"],RTC["5600"],RTC["5726"],RTC["1350"],RTC["3576"],RTC["7000"],RTC["4032"],RTC["4749"],RTC["1253"]]

############
#PARCOURS 14
############

# Arrêts normals
route_14_stops = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],
                       TCJC["10-03"],TCJC["10-02"],TCJC["10-01"],TCJC["30-04"],TCJC["30-03"],
                       TCJC["30-02"],RTC["4032"],RTC["1350"],RTC["1253"],RTC["3576"],RTC["7000"]]

# 14 direction peu achalandé n'arrête pas aux halles ni aux Saules
route_14r_stops = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],
                   TCJC["10-03"],TCJC["10-02"],TCJC["10-01"],TCJC["30-04"],TCJC["30-03"],
                   TCJC["30-02"],RTC["4032"],RTC["7000"]]

route_14r_info = Dict(
    :route_id => "TCJC:14",
    :agency_id => "tests_TCJC",
    :route_short_name => "14",
    :route_long_name => "Express SCJC - ULaval via Shannon",
    :route_type => 3, # 3 = Bus
    :route_color => "8C6CE6", # Bleu-violet
    :shape_id => "ROUTE_14",
    :stops => route_14r_stops
)

route_14r = merge(route_14r_info, compute_route(mx,route_14r_stops))

# Informations pour GTFS
route_14_info = Dict(
    :route_id => "TCJC:14",
    :agency_id => "tests_TCJC",
    :route_short_name => "14",
    :route_long_name => "Express SCJC - ULaval via Shannon",
    :route_type => 3, # 3 = Bus
    :route_color => "8C6CE6", # Bleu-violet
    :shape_id => "ROUTE_14",
    :stops => route_14_stops
)

# Calcul du temps de trajet et distances
route_14 = merge(route_14_info, compute_route(mx,route_14_stops))



#############
#PARCOURS 14X
#############

# Arrêts
route_14X_stops = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],
                       TCJC["10-03"],TCJC["10-02"],TCJC["10-01"],TCJC["30-04"],TCJC["30-03"],
                       TCJC["30-02"],RTC["4032"]]

# Informations pour GTFS
route_14X_info = Dict(
    :route_id => "TCJC:14X",
    :agency_id => "tests_TCJC",
    :route_short_name => "14X",
    :route_long_name => "SCJC - Val-Bélair via Shannon",
    :route_type => 3, # 3 = Bus
    :route_color => "8C6CE6", # Bleu-violet
    :shape_id => "ROUTE_14X",
    :stops => route_14X_stops
)

# Calcul du temps de trajet et distances
route_14X = merge(route_14X_info,compute_route(mx,route_14X_stops))


routes = [route_14,route_14X]

#########
#DÉPARTS
#########

######### AM ########

# Premier départ 14 AM

depart14AM1 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14_AM1",
    :trip_headsign => "Express SCJC vers ULaval via Shannon",
    :shape_id => "SHAPE_14",
    :stops => route_14_stops,
    :stop_times => compute_trip(route_14,Time(6,15),1.8),
    :all_route => route_14[:all_route]
)

# Deuxième départ 14 AM

depart14AM2 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14_AM2",
    :trip_headsign => "Express SCJC vers ULaval via Shannon",
    :shape_id => "SHAPE_14",
    :stops => route_14_stops,
    :stop_times => compute_trip(route_14,Time(8,20),1.3),
    :all_route => route_14[:all_route]
)

# Premier départ 14X AM

depart14XAM1 = Dict(
    :route_id => "TCJC:14X",
    :service_id => "WEEKDAY",
    :trip_id => "14X_AM1",
    :trip_headsign => "SCJC vers Val-Bélair via Shannon",
    :shape_id => "SHAPE_14X",
    :stops => route_14X_stops,
    :stop_times => compute_trip(route_14X,Time(8,20),1.3),
    :all_route => route_14X[:all_route]
)

# Deuxième départ 14X AM

depart14XAM2 = Dict(
    :route_id => "TCJC:14X",
    :service_id => "WEEKDAY",
    :trip_id => "14_AMX2",
    :trip_headsign => "SCJC vers Val-Bélair via Shannon",
    :shape_id => "SHAPE_14X",
    :stops => route_14X_stops,
    :stop_times => compute_trip(route_14X,Time(10,40),1.1),
    :all_route => route_14[:all_route]
)

# Retour du 14 en am

retour14AM1 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14r_AM1",
    :trip_headsign => "Express ULaval vers SCJC via Shannon",
    :shape_id => "ROUTE_14r_rev",
    :stops => reverse(route_14r_stops),
    :stop_times => compute_trip(route_14r,Time(7,32),1.2,reverse_direction=true),
    :all_route => reverse(route_14r[:all_route])
)


retour14AM2 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14r_AM2",
    :trip_headsign => "Express ULaval vers SCJC via Shannon",
    :shape_id => "ROUTE_14r_rev",
    :stops => reverse(route_14r_stops),
    :stop_times => compute_trip(route_14r,Time(9,15),1.0,reverse_direction=true),
    :all_route => reverse(route_14r[:all_route])
)

######### PM ########

# Premier départ 14 PM

depart14PM1 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14_PM1",
    :trip_headsign => "Express ULaval vers SCJC via Shannon",
    :shape_id => "ROUTE_14_rev",
    :stops => reverse(route_14_stops),
    :stop_times => compute_trip(route_14,Time(16,40),1.87,reverse_direction=true),
    :all_route => reverse(route_14[:all_route])
)

# Deuxième départ 14 PM

depart14PM2 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14_PM2",
    :trip_headsign => "Express ULaval vers SCJC via Shannon",
    :shape_id => "ROUTE_14_rev",
    :stops => reverse(route_14_stops),
    :stop_times => compute_trip(route_14,Time(18,40),1.2,reverse_direction=true),
    :all_route => reverse(route_14[:all_route])
)

# Premier départ 14X PM

depart14XPM1 = Dict(
    :route_id => "TCJC:14X",
    :service_id => "WEEKDAY",
    :trip_id => "14X_PM1",
    :trip_headsign => "Express ULaval vers SCJC via Shannon",
    :shape_id => "ROUTE_14X_rev",
    :stops => reverse(route_14_stops),
    :stop_times => compute_trip(route_14X,Time(12,45),1.0,reverse_direction=true),
    :all_route => reverse(route_14X[:all_route])
)

# Retour du 14 en PM

retour14PM1 = Dict(
    :route_id => "TCJC:14",
    :service_id => "WEEKDAY",
    :trip_id => "14r_PM1",
    :trip_headsign => "Express SCJC vers ULaval via Shannon",
    :shape_id => "ROUTE_14r",
    :stops => route_14r_stops,
    :stop_times => compute_trip(route_14r,Time(18,00),1.0),
    :all_route => route_14r[:all_route]
)

# Proposition 1
trips1 = [depart14AM1, depart14PM1];

# Proposition 2
trips2 = [depart14AM1, retour14AM1, depart14AM2, depart14PM1, retour14PM1, depart14PM2];

# Proposition 3
trips3 = [depart14AM1, retour14AM1, depart14AM2, retour14AM2, depart14XAM2,
          depart14XPM1, depart14PM1, retour14PM1, depart14PM2];


"Bip-Bop Bip-Bop 🤖"
end

# ╔═╡ 49fe8bd6-41c7-46ca-96bb-bf001ec4c4f6
WideCell(html"""
<h2> Proposition de modifications à l'offre de service du TCJC prévu au 1er avril pour Fossambault-sur-le-lac, Sainte-Catherine-de-la-Jacques-Cartier et Shannon</h2>
""",max_width=800)

# ╔═╡ c70e54be-50aa-43eb-894d-f626a7844ee6
WideCell(md"""### Parcours prévu au 1er avril 2026""", max_width=800)

# ╔═╡ 5fc761a3-c205-4616-8ee0-c3c609be2975
begin
	heure="06:50"
	response = callAPI((TCJC["10-07"][:stop_lat],TCJC["10-07"][:stop_lon]),
					   (RTC["5912"][:stop_lat],RTC["5912"][:stop_lon]),heure)

	itinerary = parse_itinerary(response,MAP_BOUNDS=[(46.7,-71.6),(46.9,-71.4)])
	map = itinerary[:map]

	WideCell(@htl(
	"""<div class="titre_parcours">Parcours 13<br> <p style="font-size: 14px;font-weight:normal">Fossambault -> Sainte-Catherine -> Saint-Augustin</p></div> 
			$(map)
					
"""),max_width=800)
end

# ╔═╡ 9aa1e839-79ad-46a3-a647-54e8c8b508a6
WideCell(md"""### Parcours que nous aimerions ajouter""", max_width=800)

# ╔═╡ b942dc52-cf40-4c62-a74d-96fbe19e5df4
begin
	flm = pyimport("folium")
	matplotlib_cm = pyimport("matplotlib.cm")
	matplotlib_colors = pyimport("matplotlib.colors")

	cmap2 = matplotlib_cm.get_cmap("prism")

	### PARCOURS 14 ###
	m = flm.Map()

	# Route nodes lattitude and longitude
	locs = [LLA(mx.nodes[n],mx.bounds) for n in route_14[:all_route]]

	# Stop markers
	for stop in route_14[:stops]
		flm.Marker(location=[stop["stop_lat"],stop["stop_lon"]],
				   		 popup=stop["stop_name"],
						 fill = true,
				   		 radius = 4,
						 icon= flm.Icon(color="orange",icon="bus",prefix="fa")
				   ).add_to(m) 
	end

	#Route shape
	info = "parcours 14"
	flm.PolyLine(        
	    [(loc.lat, loc.lon) for loc in locs ],
	    popup=info,
	    tooltip=info,
	    #color="#274e13"
	    color="#02547a"
	).add_to(m)

	# Map edges
	MAP_BOUNDS = [(46.78,-71.5),(46.92,-71.4)]
	m.fit_bounds(MAP_BOUNDS);

	#Temps et distance
	longueur14 = round(route_14[:total_distance]/1000, digits=2)


	### PARCOURS 14X ###
	m2 = flm.Map()
	locs2 = [LLA(mx.nodes[n],mx.bounds) for n in route_14X[:all_route]]
	for stop in route_14X[:stops]
		flm.Marker(location=[stop["stop_lat"],stop["stop_lon"]],
				   		 popup=stop["stop_name"],
						 fill = true,
				   		 radius = 4,
						 icon= flm.Icon(color="orange",icon="bus",prefix="fa")
				   ).add_to(m2) 
	end
	flm.PolyLine(        
	    [(loc.lat, loc.lon) for loc in locs2 ],
	    popup="parcours 14x",
	    #color="#274e13"
	    color="#02547a"
	).add_to(m2)
	
	m2.fit_bounds(MAP_BOUNDS);

	#Temps et distance
	longueur14X = round(route_14X[:total_distance]/1000, digits=2)

WideCell(
	@htl("""
	<style>
		.titre_parcours{
			background-color: #02547a;
			color: white;
			font-size: 18px;
			padding: 5px;
		 	text-align:center;
			font-weight: bold;
		}
		 .temps_distance{
			 background-color: #f2f3f5;
			 font-size: 13px;
			 padding: 5px;
		 }
		 .pourquoi{
			background-color:#f7f6f0;
			padding: 5px;
			border-left: 8px solid #d6d5ce;
			border-radius: 5px;
		 	margin-top:10px;
		}
		  ul li { margin-bottom: 15px; }
	</style>
		 

		 <div class="titre_parcours">Parcours 14<br> <p style="font-size: 14px;font-weight:normal">Fossambault -> Sainte-Catherine -> Shannon -> les Saules -> UL</p></div> 
		 $(m)
		 <div class="temps_distance">Longueur du trajet: $(longueur14) km</div>

		 <div class="titre_parcours">Parcours 14X<br> <p style="font-size: 14px;font-weight:normal">Fossambault -> Sainte-Catherine -> Shannon -> Route Sainte-Geneviève</p></div>
		 $(m2)
		 <div class="temps_distance">Longueur du trajet: $(longueur14X) km</div>
	<div class="pourquoi">
		<h5>Pourquoi ces parcours</h5>
		 <hr>
		<ul>
		<li> <b>Évitent les artères problématiques du aux travaux du tramway</b><br>
		<li> Le 14 permet de maintenir un <b>parcours direct pour les étudiants de l'université Laval et du cégep Ste-Foy</b>. 
		 
		<li> <b>Transferts efficaces</b> à Ste-Geneviève et aux Saules pour se rendre aux autres destinations (Écoles secondaires, centre-ville, limoilou, etc.) 
		<li> Connexion avec les <b>métrobus 803, 804 et 805</b>
		<li> <b>Voies réservés pour les bus</b> sur Henri-IV sud (573) à partir de la route Ste-Geneviève et sur Robert-Bourassa (740)
		<li> Dessert <b>3 municipalités</b> donc les frais supplémentaires pourront être partagés entre ces trois municipalités
		</ul>
	</div>
	"""), max_width=800)

end

# ╔═╡ 13d142b5-dfd8-4838-ad97-703101eda29b
md"""
**CODE**
"""

# ╔═╡ 895973ef-3dcb-49fc-ad2d-b5bb7edd5e5b
begin
	function _compute_route(mx::MapData,parcours::Array)
    """
    Computes the time and distance between stops
    """
    all_route = []

    for i in 2:length(parcours)
        route, distance, route_time = fastest_route(mx,get_node(mx,parcours[i-1]),get_node(mx,parcours[i]))
		if parcours[i-1][:rt_stop_id]=="XX"
			all_route=vcat(all_route,route[1:2])
		else
       	    all_route=vcat(all_route,route)
		end
    end  

    return all_route
end
	# modifications au tracé pour forcer le passage sur la 40
	route_14_modif = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],
						   TCJC["10-03"],TCJC["10-02"],TCJC["10-01"],TCJC["30-04"],TCJC["30-03"],
						   TCJC["30-02"],RTC["4032"],
						   Dict(:rt_stop_id => "XXX", :stop_lat =>  46.8181977 , :stop_lon => -71.3513177),
					  	   Dict(:rt_stop_id => "XX",:stop_lat =>  46.8164450, :stop_lon => -71.3256676),
						   RTC["1350"],RTC["1253"],RTC["3576"],RTC["7000"]]
	
	route_14[:all_route]=_compute_route(mx,route_14_modif)
	"Bip-Bip-Boup"
end

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
HTTP = "cd3eb016-35fb-5094-929b-558a96fad6f3"
HypertextLiteral = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
OpenStreetMapX = "86cd37e6-c0ff-550b-95fe-21d72c8d4fc9"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
PrettyTables = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"
PyCall = "438e738f-606a-5dbb-bf0a-cddfbfd45ab0"

[compat]
CSV = "~0.10.15"
DataFrames = "~1.8.1"
HTTP = "~1.11.0"
HypertextLiteral = "~1.0.0"
JSON3 = "~1.14.3"
OpenStreetMapX = "~0.4.1"
PlutoUI = "~0.7.79"
PrettyTables = "~3.1.0"
PyCall = "~1.96.4"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.1"
manifest_format = "2.0"
project_hash = "cf7f8821a7dde9b88b1c79dcea9364ee592fb20f"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "6e1d2a35f2f90a4bc7c2ed98079b2ba09c35b83a"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.3.2"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.2"

[[deps.ArnoldiMethod]]
deps = ["LinearAlgebra", "Random", "StaticArrays"]
git-tree-sha1 = "d57bd3762d308bded22c3b82d033bff85f6195c6"
uuid = "ec485272-7323-5ecc-a04f-4719b315124d"
version = "0.4.0"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
version = "1.11.0"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
version = "1.11.0"

[[deps.BitFlags]]
git-tree-sha1 = "0691e34b3bb8be9307330f88d1a3c3f25466c24d"
uuid = "d1d4a3ce-64b1-5f1a-9ba4-7e7e69966f35"
version = "0.1.9"

[[deps.BufferedStreams]]
git-tree-sha1 = "6863c5b7fc997eadcabdbaf6c5f201dc30032643"
uuid = "e1450e63-4bb3-523b-b2a4-4ffa8c0fd77d"
version = "1.2.2"

[[deps.CSV]]
deps = ["CodecZlib", "Dates", "FilePathsBase", "InlineStrings", "Mmap", "Parsers", "PooledArrays", "PrecompileTools", "SentinelArrays", "Tables", "Unicode", "WeakRefStrings", "WorkerUtilities"]
git-tree-sha1 = "deddd8725e5e1cc49ee205a1964256043720a6c3"
uuid = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
version = "0.10.15"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "962834c22b66e32aa10f7611c08c8ca4e20749a9"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.8"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "67e11ee83a43eb71ddc950302c53bf33f0690dfe"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.12.1"
weakdeps = ["StyledStrings"]

    [deps.ColorTypes.extensions]
    StyledStringsExt = "StyledStrings"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "9d8a54ce4b17aa5bdce0ea5c34bc5e7c340d16ad"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.18.1"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.3.0+1"

[[deps.ConcurrentUtilities]]
deps = ["Serialization", "Sockets"]
git-tree-sha1 = "21d088c496ea22914fe80906eb5bce65755e5ec8"
uuid = "f0e56b4a-5159-44fe-b623-3e5288b988bb"
version = "2.5.1"

[[deps.Conda]]
deps = ["Downloads", "JSON", "VersionParsing"]
git-tree-sha1 = "8f06b0cfa4c514c7b9546756dbae91fcfbc92dc9"
uuid = "8f4d0f93-b110-5947-807f-2305c1781a2d"
version = "1.10.3"

[[deps.Crayons]]
git-tree-sha1 = "249fe38abf76d48563e2f4556bebd215aa317e15"
uuid = "a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"
version = "4.1.1"

[[deps.DataAPI]]
git-tree-sha1 = "abe83f3a2f1b857aac70ef8b269080af17764bbe"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.16.0"

[[deps.DataFrames]]
deps = ["Compat", "DataAPI", "DataStructures", "Future", "InlineStrings", "InvertedIndices", "IteratorInterfaceExtensions", "LinearAlgebra", "Markdown", "Missings", "PooledArrays", "PrecompileTools", "PrettyTables", "Printf", "Random", "Reexport", "SentinelArrays", "SortingAlgorithms", "Statistics", "TableTraits", "Tables", "Unicode"]
git-tree-sha1 = "d8928e9169ff76c6281f39a659f9bca3a573f24c"
uuid = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
version = "1.8.1"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "4e1fe97fdaed23e9dc21d4d664bea76b65fc50a0"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.22"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
version = "1.11.0"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"
version = "1.11.0"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.EnumX]]
git-tree-sha1 = "7bebc8aad6ee6217c78c5ddcf7ed289d65d0263e"
uuid = "4e289a0a-7415-4d19-859d-a7e5c4648b56"
version = "1.0.6"

[[deps.ExceptionUnwrapping]]
deps = ["Test"]
git-tree-sha1 = "d36f682e590a83d63d1c7dbd287573764682d12a"
uuid = "460bff9d-24e4-43bc-9d9f-a8973cb893f4"
version = "0.1.11"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "27af30de8b5445644e8ffe3bcb0d72049c089cf1"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.7.3+0"

[[deps.FilePathsBase]]
deps = ["Compat", "Dates"]
git-tree-sha1 = "3bab2c5aa25e7840a4b065805c0cdfc01f3068d2"
uuid = "48062228-2e41-5def-b9a4-89aafe57970f"
version = "0.9.24"
weakdeps = ["Mmap", "Test"]

    [deps.FilePathsBase.extensions]
    FilePathsBaseMmapExt = "Mmap"
    FilePathsBaseTestExt = "Test"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"
version = "1.11.0"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "05882d6995ae5c12bb5f36dd2ed3f61c98cbb172"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.5"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"
version = "1.11.0"

[[deps.Graphs]]
deps = ["ArnoldiMethod", "DataStructures", "Distributed", "Inflate", "LinearAlgebra", "Random", "SharedArrays", "SimpleTraits", "SparseArrays", "Statistics"]
git-tree-sha1 = "7a98c6502f4632dbe9fb1973a4244eaa3324e84d"
uuid = "86223c79-3864-5bf0-83f7-82e725a168b6"
version = "1.13.1"

[[deps.HTTP]]
deps = ["Base64", "CodecZlib", "ConcurrentUtilities", "Dates", "ExceptionUnwrapping", "Logging", "LoggingExtras", "MbedTLS", "NetworkOptions", "OpenSSL", "PrecompileTools", "Random", "SimpleBufferStream", "Sockets", "URIs", "UUIDs"]
git-tree-sha1 = "51059d23c8bb67911a2e6fd5130229113735fc7e"
uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"
version = "1.11.0"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "179267cfa5e712760cd43dcae385d7ea90cc25a4"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.5"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "d1a86724f81bcd184a38fd284ce183ec067d71a0"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "1.0.0"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "0ee181ec08df7d7c911901ea38baf16f755114dc"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "1.0.0"

[[deps.Inflate]]
git-tree-sha1 = "d1b1b796e47d94588b3757fe84fbf65a5ec4a80d"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.5"

[[deps.InlineStrings]]
git-tree-sha1 = "8f3d257792a522b4601c24a577954b0a8cd7334d"
uuid = "842dd82b-1e85-43dc-bf29-5d0ee9dffc48"
version = "1.4.5"

    [deps.InlineStrings.extensions]
    ArrowTypesExt = "ArrowTypes"
    ParsersExt = "Parsers"

    [deps.InlineStrings.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"
    Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"
version = "1.11.0"

[[deps.InvertedIndices]]
git-tree-sha1 = "6da3c4316095de0f5ee2ebd875df8721e7e0bdbe"
uuid = "41ab1584-1d38-5bbf-9106-f11c6c58b48f"
version = "1.3.1"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "0533e564aae234aff59ab625543145446d8b6ec2"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.7.1"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "31e996f0a15c7b280ba9f76636b3ff9e2ae58c9a"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.4"

[[deps.JSON3]]
deps = ["Dates", "Mmap", "Parsers", "PrecompileTools", "StructTypes", "UUIDs"]
git-tree-sha1 = "411eccfe8aba0814ffa0fdf4860913ed09c34975"
uuid = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
version = "1.14.3"

    [deps.JSON3.extensions]
    JSON3ArrowExt = ["ArrowTypes"]

    [deps.JSON3.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"

[[deps.JuliaSyntaxHighlighting]]
deps = ["StyledStrings"]
uuid = "ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"
version = "1.12.0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "dda21b8cbd6a6c40d9d02a73230f9d70fed6918c"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.4.0"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "OpenSSL_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.11.1+1"

[[deps.LibExpat]]
deps = ["Expat_jll", "Pkg"]
git-tree-sha1 = "27dc51f94ceb107fd53b367431a638b430e01e81"
uuid = "522f3ed2-3f36-55e3-b6df-e94fee9b0c07"
version = "0.6.1"

[[deps.LibGit2]]
deps = ["LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"
version = "1.11.0"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "OpenSSL_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.9.0+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "OpenSSL_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.3+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.12.0"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"
version = "1.11.0"

[[deps.LoggingExtras]]
deps = ["Dates", "Logging"]
git-tree-sha1 = "f00544d95982ea270145636c181ceda21c4e2575"
uuid = "e6f89c97-d47a-5376-807f-9c37f3926c36"
version = "1.2.0"

[[deps.MIMEs]]
git-tree-sha1 = "c64d943587f7187e751162b3b84445bbbd79f691"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "1.1.0"

[[deps.MacroTools]]
git-tree-sha1 = "1e0228a030642014fe5cfe68c2c0a818f9e3f522"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.16"

[[deps.Markdown]]
deps = ["Base64", "JuliaSyntaxHighlighting", "StyledStrings"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.MbedTLS]]
deps = ["Dates", "MbedTLS_jll", "MozillaCACerts_jll", "NetworkOptions", "Random", "Sockets"]
git-tree-sha1 = "8785729fa736197687541f7053f6d8ab7fc44f92"
uuid = "739be429-bea8-5141-9913-cc70e7f3736d"
version = "1.1.10"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "ff69a2b1330bcb730b9ac1ab7dd680176f5896b8"
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.1010+0"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "ec4f7fbeab05d7747bdf98eb74d130a2a2ed298d"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.2.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"
version = "1.11.0"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2025.5.20"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.3.0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.29+0"

[[deps.OpenSSL]]
deps = ["BitFlags", "Dates", "MozillaCACerts_jll", "NetworkOptions", "OpenSSL_jll", "Sockets"]
git-tree-sha1 = "1d1aaa7d449b58415f97d2839c318b70ffb525a0"
uuid = "4d8831e6-92b7-49fb-bdf8-b643e874388c"
version = "1.6.1"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.5.1+0"

[[deps.OpenStreetMapX]]
deps = ["CodecZlib", "DataStructures", "Graphs", "HTTP", "JSON", "LibExpat", "ProtoBuf", "Random", "Serialization", "SparseArrays", "StableRNGs", "Statistics"]
git-tree-sha1 = "4ace81bb47e44b6c4abdfbb56893a55773613c81"
uuid = "86cd37e6-c0ff-550b-95fe-21d72c8d4fc9"
version = "0.4.1"

[[deps.OrderedCollections]]
git-tree-sha1 = "05868e21324cede2207c6f0f466b4bfef6d5e7ee"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.8.1"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "7d2f8f21da5db6a806faf7b9b292296da42b2810"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.3"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "FileWatching", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "Random", "SHA", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.12.0"
weakdeps = ["REPL"]

    [deps.Pkg.extensions]
    REPLExt = "REPL"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "Downloads", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "3ac7038a98ef6977d44adeadc73cc6f596c08109"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.79"

[[deps.PooledArrays]]
deps = ["DataAPI", "Future"]
git-tree-sha1 = "36d8b4b899628fb92c2749eb488d884a926614d3"
uuid = "2dfb63ee-cc39-5dd5-95bd-886bf059d720"
version = "1.4.3"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "07a921781cab75691315adc645096ed5e370cb77"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.3.3"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "8b770b60760d4451834fe79dd483e318eee709c4"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.5.2"

[[deps.PrettyTables]]
deps = ["Crayons", "LaTeXStrings", "Markdown", "PrecompileTools", "Printf", "REPL", "Reexport", "StringManipulation", "Tables"]
git-tree-sha1 = "6b8e2f0bae3f678811678065c09571c1619da219"
uuid = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
version = "3.1.0"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
version = "1.11.0"

[[deps.ProtoBuf]]
deps = ["BufferedStreams", "Dates", "EnumX", "TOML"]
git-tree-sha1 = "eabdb811dbacadc9d7e0dee9ac11c1a12705e12a"
uuid = "3349acd9-ac6a-5e09-bcdb-63829b23a429"
version = "1.2.0"

[[deps.PyCall]]
deps = ["Conda", "Dates", "Libdl", "LinearAlgebra", "MacroTools", "Serialization", "VersionParsing"]
git-tree-sha1 = "9816a3826b0ebf49ab4926e2b18842ad8b5c8f04"
uuid = "438e738f-606a-5dbb-bf0a-cddfbfd45ab0"
version = "1.96.4"

[[deps.REPL]]
deps = ["InteractiveUtils", "JuliaSyntaxHighlighting", "Markdown", "Sockets", "StyledStrings", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"
version = "1.11.0"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.11.0"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SentinelArrays]]
deps = ["Dates", "Random"]
git-tree-sha1 = "712fb0231ee6f9120e005ccd56297abbc053e7e0"
uuid = "91c51154-3ec4-41a3-a24f-3f23e20d615c"
version = "1.4.8"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
version = "1.11.0"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"
version = "1.11.0"

[[deps.SimpleBufferStream]]
git-tree-sha1 = "f305871d2f381d21527c770d4788c06c097c9bc1"
uuid = "777ac1f9-54b0-4bf8-805c-2214025038e7"
version = "1.2.0"

[[deps.SimpleTraits]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "be8eeac05ec97d379347584fa9fe2f5f76795bcb"
uuid = "699a6c99-e7fa-54fc-8d76-47d257e15c1d"
version = "0.9.5"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"
version = "1.11.0"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "64d974c2e6fdf07f8155b5b2ca2ffa9069b608d9"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.2.2"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.12.0"

[[deps.StableRNGs]]
deps = ["Random"]
git-tree-sha1 = "4f96c596b8c8258cc7d3b19797854d368f243ddc"
uuid = "860ef19b-820b-49d6-a774-d7a799459cd3"
version = "1.0.4"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "PrecompileTools", "Random", "StaticArraysCore"]
git-tree-sha1 = "b8693004b385c842357406e3af647701fe783f98"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.9.15"

    [deps.StaticArrays.extensions]
    StaticArraysChainRulesCoreExt = "ChainRulesCore"
    StaticArraysStatisticsExt = "Statistics"

    [deps.StaticArrays.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

[[deps.StaticArraysCore]]
git-tree-sha1 = "6ab403037779dae8c514bad259f32a447262455a"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.4"

[[deps.Statistics]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "ae3bb1eb3bba077cd276bc5cfc337cc65c3075c0"
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.11.1"
weakdeps = ["SparseArrays"]

    [deps.Statistics.extensions]
    SparseArraysExt = ["SparseArrays"]

[[deps.StringManipulation]]
deps = ["PrecompileTools"]
git-tree-sha1 = "725421ae8e530ec29bcbdddbe91ff8053421d023"
uuid = "892a3eda-7b42-436c-8928-eab12a02cf0e"
version = "0.4.1"

[[deps.StructTypes]]
deps = ["Dates", "UUIDs"]
git-tree-sha1 = "159331b30e94d7b11379037feeb9b690950cace8"
uuid = "856f2bd8-1eba-4b0a-8007-ebc267875bd4"
version = "1.11.0"

[[deps.StyledStrings]]
uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
version = "1.11.0"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.8.3+2"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "OrderedCollections", "TableTraits"]
git-tree-sha1 = "f2c1efbc8f3a609aadf318094f8fc5204bdaf344"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.12.1"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.0"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
version = "1.11.0"

[[deps.TranscodingStreams]]
git-tree-sha1 = "0c45878dcfdcfa8480052b6ab162cdd138781742"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.11.3"

[[deps.Tricks]]
git-tree-sha1 = "311349fd1c93a31f783f977a71e8b062a57d4101"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.13"

[[deps.URIs]]
git-tree-sha1 = "bef26fb046d031353ef97a82e3fdb6afe7f21b1a"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.6.1"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.VersionParsing]]
git-tree-sha1 = "58d6e80b4ee071f5efd07fda82cb9fbe17200868"
uuid = "81def892-9a0e-5fdd-b105-ffc91e053289"
version = "1.3.0"

[[deps.WeakRefStrings]]
deps = ["DataAPI", "InlineStrings", "Parsers"]
git-tree-sha1 = "b1be2855ed9ed8eac54e5caff2afcdb442d52c23"
uuid = "ea10d353-3f73-51f8-a26c-33c1cb351aa5"
version = "1.4.2"

[[deps.WorkerUtilities]]
git-tree-sha1 = "cd1659ba0d57b71a464a29e64dbc67cfe83d54e7"
uuid = "76eceee3-57b5-4d4a-8e66-0e911cebbf60"
version = "1.6.1"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.3.1+2"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.15.0+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.64.0+1"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.5.0+2"
"""

# ╔═╡ Cell order:
# ╟─49fe8bd6-41c7-46ca-96bb-bf001ec4c4f6
# ╟─c70e54be-50aa-43eb-894d-f626a7844ee6
# ╟─5fc761a3-c205-4616-8ee0-c3c609be2975
# ╟─9aa1e839-79ad-46a3-a647-54e8c8b508a6
# ╟─b942dc52-cf40-4c62-a74d-96fbe19e5df4
# ╟─13d142b5-dfd8-4838-ad97-703101eda29b
# ╟─43eb24bf-4357-4a51-ab12-a2fd000b9cf1
# ╟─895973ef-3dcb-49fc-ad2d-b5bb7edd5e5b
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
