import AWSClusterManagers.OverlayManagers.Transport: OverlayMessage, OverlayNetwork

@testset "message encoding" begin
    io = IOBuffer()
    write(io, OverlayMessage(1, 2, "hello"))
    seekstart(io)
    msg = read(io, OverlayMessage)

    @test msg.src == 1
    @test msg.dest == 2
    @test String(msg.payload) == "hello"
end

@testset "send to self" begin
    broker = spawn_broker()

    net = OverlayNetwork(1)
    msg = OverlayMessage(1, 1, "helloworld!")
    write(net.sock, msg)
    result = read(net.sock, OverlayMessage)

    @test result == msg

    close(net.sock)
    kill(broker); wait(broker)
end

@testset "echo" begin
    broker = spawn_broker()

    @schedule begin
        _net = OverlayNetwork(2)
        incoming = read(_net.sock, OverlayMessage)
        outgoing = OverlayMessage(2, incoming.src, "REPLY: $(String(incoming.payload))")
        write(_net.sock, outgoing)
        close(_net.sock)
    end
    yield()

    net = OverlayNetwork(1)
    msg = OverlayMessage(1, 2, "helloworld!")
    write(net.sock, msg)
    result = read(net.sock, OverlayMessage)

    @test result.src == 2
    @test result.dest == 1
    @test String(result.payload) == "REPLY: helloworld!"

    close(net.sock)
    kill(broker); wait(broker)
end
