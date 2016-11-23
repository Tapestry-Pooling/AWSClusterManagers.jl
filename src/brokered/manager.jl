import Base: launch, manage, connect, kill

type BrokeredManager <: ClusterManager
    np::Int
    node::Node
end

BrokeredManager(np::Integer) = BrokeredManager(Int(np), Node(0))

function launch(manager::BrokeredManager, params::Dict, launched::Array, c::Condition)
    node = manager.node
    @schedule while true
        (from_zid, data) = recv(node)
        println("MANAGER")

        # TODO: Do what worker does?
        (r_s, w_s) = node.streams[from_zid]
        unsafe_write(r_s, pointer(data), length(data))
    end

    for i in 1:manager.np
        # spawn(`$(params[:exename]) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_worker($i, \"$(Base.cluster_cookie())\")"`)

        wconfig = WorkerConfig()
        wconfig.userdata = Dict{Symbol,Any}(:id=>i)
        push!(launched, wconfig)
        notify(c)
    end
end

# Used by the manager or workers to connect to estabilish connections to other nodes in the
# cluster.
function connect(manager::BrokeredManager, pid::Int, config::WorkerConfig)
    #println("connect_m2w")
    if myid() == 1
        zid = get(config.userdata)[:id]
        config.connect_at = zid # This will be useful in the worker-to-worker connection setup.
    else
        #println("connect_w2w")
        zid = get(config.connect_at)
        config.userdata = Dict{Symbol,Any}(:id=>zid)
    end

    # Curt: I think this is just used by the manager
    node = manager.node
    println("Connect $(node.id) -> $zid")
    streams = get!(node.streams, zid) do
        println("Establish connection $(node.id) -> $zid")
        setup_connection(node, zid)
    end

    udata = get(config.userdata)
    udata[:streams] = streams

    streams
end

function manage(manager::BrokeredManager, id::Int, config::WorkerConfig, op)
    nothing
end

function kill(manager::BrokeredManager, pid::Int, config::WorkerConfig)
    # send(manager.node, get(config.userdata)[:id], CONTROL_MSG, KILL_MSG)
    (r_s, w_s) = get(config.userdata)[:streams]
    close(r_s)
    close(w_s)

    # Terminate socket from manager to broker when all workers have been killed
    # Doesn't work?
    node = manager.node
    if isempty(node.streams)
        close(node.sock)
    end

    nothing
end
