using CSV, DataFrames, ZipArchives


function write_gtfs(stops::Array, routes::Array, trips::Array, folder::String, zip_name::String)

"""
Writes a zip_name_gtfs.zip file in folder given a list of stops, routes and trips
"""

    # Agency
    agency_df = DataFrame(
        agency_id="tests_TCJC",
        agency_name="Tests de nouveaux parcours pour le TCJC",
        agency_url="https://www.thefunbus.org",
        agency_timezone="America/Montreal",
        agency_phone="418-555-1234",
        agency_lang="fr"
)
    # Calendar
    calendar_df = DataFrame(
        service_id = ["WEEKDAY"],
        monday=[1], tuesday=[1], wednesday=[1], thursday=[1], friday=[1],
        saturday=[0], sunday=[0],
        start_date=["20260101"], end_date=["20271231"]
    )


    # Arrêts
    stops_df = DataFrame(
        stop_id = [s[:rt_stop_id] for s in stops],
        stop_name = [s[:stop_name] for s in stops],
        stop_lat = [s[:stop_lat] for s in stops], 
        stop_lon = [s[:stop_lon] for s in stops] 
    )

    # Parcours
    routes_df = DataFrame(
        route_id = [r[:route_id] for r in routes],
        agency_id = [r[:agency_id] for r in routes],
        route_short_name = [r[:route_short_name] for r in routes],
        route_long_name = [r[:route_long_name] for r in routes],
        route_type = [r[:route_type] for r in routes], # 3 = Bus
        route_color = [r[:route_color] for r in routes]
    )

    # Départs
    trips_df = DataFrame(
        route_id = [t[:route_id] for t in trips],
        service_id = "WEEKDAY",
        trip_id = [t[:trip_id] for t in trips],
        trip_headsign = [t[:trip_headsign] for t in trips],
        shape_id = [t[:shape_id] for t in trips]
    )


    # Stop times
    trip_id = Vector{String}() 
    departure_time = Vector{String}() 
    stop_id = Vector{String}()
    stop_sequence = Vector{Int}()

    for t in trips
        for (i,s) in enumerate(t[:stop_times])
            push!(trip_id,t[:trip_id]);
            push!(departure_time,s);
            push!(stop_id,t[:stops][i][:rt_stop_id]);
            push!(stop_sequence,i)
        end
    end
        
    stop_times_df = DataFrame(
        trip_id = trip_id,
        arrival_time = departure_time,
        departure_time = departure_time,
        stop_id = stop_id,
        stop_sequence = stop_sequence
    )

    # Shape
    shape_id = Vector{String}()
    shape_pt_lat = Vector{Float64}()
    shape_pt_lon = Vector{Float64}()
    shape_pt_sequence = Vector{Int}()

    for t in trips
        for (i,p) in enumerate(t[:all_route])
            push!(shape_id, t[:shape_id])
            push!(shape_pt_lat, LLA(mx.nodes[p],mx.bounds).lat)
            push!(shape_pt_lon, LLA(mx.nodes[p],mx.bounds).lon)
            push!(shape_pt_sequence, i)
        end
    end
 
    
    shapes_df = DataFrame(
        shape_id = shape_id,
        shape_pt_lat = shape_pt_lat,
        shape_pt_lon = shape_pt_lon,
        shape_pt_sequence = shape_pt_sequence
    )
    
    # Write .zip

    ZipWriter(folder*"/"*zip_name*"_gtfs.zip") do w

        zip_newfile(w, "agency.txt")
        CSV.write(w, agency_df)

        zip_newfile(w, "calendar.txt")
        CSV.write(w, calendar_df)

        zip_newfile(w, "stops.txt")
        CSV.write(w, stops_df)

        zip_newfile(w,"routes.txt")
        CSV.write(w, routes_df)

        zip_newfile(w,"trips.txt")
        CSV.write(w, trips_df)

        zip_newfile(w,"stop_times.txt")
        CSV.write(w, stop_times_df)

        zip_newfile(w, "shapes.txt")
        CSV.write(w, shapes_df)
    end
end


