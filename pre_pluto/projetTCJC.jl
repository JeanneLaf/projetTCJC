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
TCJC["30-07"] = Dict(:stop_name => "Chemin Dublin / rue de Bretagne",
					 :stop_lat => 46.8736608,
					 :stop_lon => -71.5288398,
					 :rt_stop_id => "30-07")
TCJC["30-08"] = Dict(:stop_name => "Chemin Dublin / rue du Parc",
					 :stop_lat => 46.8851185,
					 :stop_lon => -71.5286014,
					 :rt_stop_id => "30-08")
TCJC["30-09"] = Dict(:stop_name => "Chemin de Gosford / Chemin de Wexford",
					 :stop_lat => 46.9108404,
					 :stop_lon => -71.5390772,
					 :rt_stop_id => "30-09")
TCJC["30-10"] = Dict(:stop_name => "Chemin de Gosford / rue Donaldson",
					 :stop_lat => 46.9213040,
					 :stop_lon => -71.5518348,
					 :rt_stop_id => "30-10")
TCJC["30-11"] = Dict(:stop_name => "rue Donaldson / rue Miller",
					 :stop_lat => 46.9139910,
					 :stop_lon => -71.5454946,
					 :rt_stop_id => "30-11")

TCJC["CFBV-01"] = Dict(:stop_name => "Général-Tremblay / Chassé",
					   :stop_lat => 46.8862066,
					   :stop_lon =>  -71.4892470,
					   :rt_stop_id => "CFBV-01")
TCJC["CFBV-02"] = Dict(:stop_name => "Général-Tremblay / Cardin",
					   :stop_lat => 46.8892958,
					   :stop_lon =>  -71.4920285,
					   :rt_stop_id => "CFBV-02")
TCJC["CFBV-03"] = Dict(:stop_name => "Général-Tremblay / Joseph-Kaeble",
					   :stop_lat =>  46.8954112,
					   :stop_lon =>  -71.4918131,
					   :rt_stop_id => "CFBV-03")
TCJC["CFBV-04"] = Dict(:stop_name => "Général-Tremblay / Joseph-Kaeble",
					   :stop_lat =>  46.8954112,
					   :stop_lon =>  -71.4918131,
					   :rt_stop_id => "CFBV-04")
############
#PARCOURS 33
############
#route_33_stops = [TCJC["30-10"], TCJC["30-11"],TCJC["30-09"],TCJC["30-04"],TCJC["30-07"],TCJC["30-08"],TCJC["30-06"],TCJC["30-04"],TCJC["30-03"],TCJC["30-02"],RTC["5600"],TCJC["CFBV-01"],TCJC["CFBV-02"],TCJC["CFBV-03"]]
route_33_stops = [TCJC["10-07"],TCJC["10-06"],TCJC["10-05"],TCJC["10-04"],TCJC["10-08"],TCJC["30-07"],TCJC["30-08"],TCJC["30-06"],TCJC["30-04"],TCJC["30-03"],TCJC["30-02"]]

# Informations pour GTFS
route_33_info = Dict(
    :route_id => "TCJC:33",
    :agency_id => "tests_TCJC",
    :route_short_name => "33",
    :route_long_name => "Fossambault-sur-le-lac - Shannon",
    :route_type => 3, # 3 = Bus
    :route_color => "00a1e5", 
    :shape_id => "ROUTE_33",
    :stops => route_33_stops
)

# Calcul du temps de trajet et distances
route_33 = merge(route_33_info, compute_route(mx,route_33_stops))
############
#PARCOURS 14
############

# Arrêts normals
route_14_stops = [TCJC["10-01"],TCJC["10-02"],TCJC["10-03"],TCJC["30-04"],TCJC["30-03"],TCJC["30-02"],RTC["4032"],RTC["1350"],RTC["1253"],RTC["3576"],RTC["7000"]]

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

# ╔═╡ 9aa1e839-79ad-46a3-a647-54e8c8b508a6
WideCell(md"""### Parcours que nous aimerions ajouter""", max_width=800)

# ╔═╡ 6ddd2a99-0b99-4fb7-9406-392ccffb1982
md"""
Distance: $(round(route_33[:total_distance]/1000)) km, Temps: $(round(route_33[:total_time]/60)) minutes
"""

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
		flm.CircleMarker(location=[stop["stop_lat"],stop["stop_lon"]],
				   		 popup=stop["stop_name"],
						 fill = true,
				   		 radius = 2,
						 color = "#e69800"
				   ).add_to(m) 
	end

	#Route shape
	info = "parcours 14"
	flm.PolyLine(        
	    [(loc.lat, loc.lon) for loc in locs ],
	    popup=info,
	    tooltip=info,
	    color="#e69800"
	    #color="#02547a"
	).add_to(m)

	# Map edges
	MAP_BOUNDS = [(46.78,-71.5),(46.92,-71.4)]
	m.fit_bounds(MAP_BOUNDS);
end

# ╔═╡ 0f53d0d8-8d0d-4d49-887b-6dd4f2e43bb2
begin
	### PARCOURS 33 ###
		m3 = flm.Map()
		locs3 = [LLA(mx.nodes[n],mx.bounds) for n in route_33[:all_route]]
		for stop in route_33[:stops]
			flm.CircleMarker(location=[stop[:stop_lat],stop[:stop_lon]],
					   		 popup=stop[:stop_name],
							 fill = true,
					   		 radius = 2,
							 color = "#00a1e5"
					   ).add_to(m) 
		end
		flm.PolyLine(        
		    [(loc.lat, loc.lon) for loc in locs3 ],
		    popup="parcours 33",
		    #color="#274e13"
		    color="#00a1e5"
		).add_to(m)
		
		m3.fit_bounds(MAP_BOUNDS);
	WideCell(m)
end

# ╔═╡ 13d142b5-dfd8-4838-ad97-703101eda29b
md"""
**CODE**
"""

# ╔═╡ 895973ef-3dcb-49fc-ad2d-b5bb7edd5e5b
# ╠═╡ disabled = true
#=╠═╡
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
  ╠═╡ =#

# ╔═╡ Cell order:
# ╟─49fe8bd6-41c7-46ca-96bb-bf001ec4c4f6
# ╟─c70e54be-50aa-43eb-894d-f626a7844ee6
# ╟─9aa1e839-79ad-46a3-a647-54e8c8b508a6
# ╟─0f53d0d8-8d0d-4d49-887b-6dd4f2e43bb2
# ╟─6ddd2a99-0b99-4fb7-9406-392ccffb1982
# ╟─b942dc52-cf40-4c62-a74d-96fbe19e5df4
# ╟─13d142b5-dfd8-4838-ad97-703101eda29b
# ╠═43eb24bf-4357-4a51-ab12-a2fd000b9cf1
# ╠═895973ef-3dcb-49fc-ad2d-b5bb7edd5e5b
