function start_worker(id::Integer, cookie::AbstractString, broker::IPAddr, port::Integer)
    #println("start_worker")
    node = Node(id, broker, port)
    dummy = BrokeredManager(node)  # Needed for use in `connect`
    Base.init_worker(cookie, dummy)

    manager_id = 1

    # Inform the manager that the worker is ready
    send(node, manager_id, HELLO_TYPE)

    while !eof(node.sock)
        msg = recv(node)
        from = msg.src

        if msg.typ == UNREACHABLE_TYPE
            debug("Receive UNREACHABLE from $from")

            if haskey(node.streams, from)
                (r_s, w_s) = node.streams[from]
                close(r_s)
                close(w_s)
            end

            from == manager_id && break
        elseif msg.typ == DATA_TYPE
            debug("Receive DATA from $from")

            # Note: To keep compatibility with the underlying ClusterManager implementation we
            # need to have incoming/outgoing streams. Typically these streams are created in
            # `connect` when initiating a connection to a worker but it also needs to be done
            # on the receiving side.
            (read_stream, write_stream) = get!(node.streams, from) do
                println("Establish connection worker $(node.id) -> $from")
                (r_s, w_s) = setup_connection(node, from)
                Base.process_messages(r_s, w_s)
                (r_s, w_s)
            end

            isopen(read_stream) && unsafe_write(read_stream, pointer(msg.payload), length(msg.payload))
        elseif msg.typ == KILL_TYPE
            debug("Receive KILL from $from")
            break
        else
            error("Unhandled message type: $(msg.typ)")
        end
    end
end
