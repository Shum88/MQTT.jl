# commands
const CONNECT = 0x10
const CONNACK = 0x20
const PUBLISH = 0x30
const PUBACK = 0x40
const PUBREC = 0x50
const PUBREL = 0x60
const PUBCOMP = 0x70
const SUBSCRIBE = 0x80
const SUBACK = 0x90
const UNSUBSCRIBE = 0xA0
const UNSUBACK = 0xB0
const PINGREQ = 0xC0
const PINGRESP = 0xD0
const DISCONNECT = 0xE0

@enum(QOS::UInt8,
    QOS_0 = 0x00,
    QOS_1 = 0x01,
    QOS_2 = 0x02)

# connect return code
const CONNECTION_ACCEPTED = 0x00
const CONNECTION_REFUSED_UNACCEPTABLE_PROTOCOL_VERSION = 0x01
const CONNECTION_REFUSED_IDENTIFIER_REJECTED = 0x02
const CONNECTION_REFUSED_SERVER_UNAVAILABLE = 0x03
const CONNECTION_REFUSED_BAD_USER_NAME_OR_PASSWORD = 0x04
const CONNECTION_REFUSED_NOT_AUTHORIZED = 0x05

struct MQTTException <: Exception
    msg::AbstractString
end

struct Packet
    cmd::UInt8
    data::Any
end

struct Message
    dup::Bool
    qos::UInt8
    retain::Bool
    topic::String
    payload::Array{UInt8}

    function Message(qos::QOS, topic::String, payload...)
        return Message(false, convert(UInt8, qos), false, topic, payload...)
    end

    function Message(dup::Bool, qos::QOS, retain::Bool, topic::String, payload...)
        return Message(dup, convert(UInt8, qos), retain, topic, payload...)
    end

    function Message(dup::Bool, qos::UInt8, retain::Bool, topic::String, payload...)
        # Convert payload to UInt8 Array with PipeBuffer
        buffer = PipeBuffer()
        for i in payload
            write(buffer, i)
        end
        encoded_payload = take!(buffer)
        return new(dup, qos, retain, topic, encoded_payload)
    end
end

struct User
    name::String
    password::String
end

mutable struct Client
    on_msg::Function
    keep_alive::UInt16

    # TODO mutex?
    last_id::UInt16
    in_flight::Dict{UInt16, Future}

    write_packets::Channel{Packet}
    socket
    socket_lock::ReentrantLock

    ping_timeout::UInt64

    # TODO remove atomic?
    ping_outstanding::Atomic{UInt8}
    last_sent::Atomic{Float64}
    last_received::Atomic{Float64}

    exit_flag::Bool
    disconnect_ready::Bool
    disconnect_ready_cond::Condition

    Client(on_msg::Function) = new(
    on_msg,
    0x0000,
    0x0000,
    Dict{UInt16, Future}(),
    Channel{Packet}(60),
    TCPSocket(),
    ReentrantLock(),
    60,
    Atomic{UInt8}(0),
    Atomic{Float64}(),
    Atomic{Float64}(),
    false,
    true,
    Condition())

    Client(on_msg::Function, ping_timeout::UInt64) = new(
    on_msg,
    0x0000,
    0x0000,
    Dict{UInt16, Future}(),
    Channel{Packet}(60),
    TCPSocket(),
    ReentrantLock(),
    ping_timeout,
    Atomic{UInt8}(0),
    Atomic{Float64}(),
    Atomic{Float64}(),
    false,
    true,
    Condition())
end



const CONNACK_ERRORS = Dict{UInt8, String}(
0x01 => "connection refused unacceptable protocol version",
0x02 => "connection refused identifier rejected",
0x03 => "connection refused server unavailable",
0x04 => "connection refused bad user name or password",
0x05 => "connection refused not authorized",
)

function handle_connack(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    session_present = read(s, UInt8)
    return_code = read(s, UInt8)

    future = client.in_flight[0x0000]
    if return_code == CONNECTION_ACCEPTED
        put!(future, session_present)
    else
        error = get(CONNACK_ERRORS, return_code, "unkown return code [" + return_code + "]")
        put!(future, MQTTException(error))
    end
end

function handle_publish(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    dup = (flags & 0x08) >> 3
    qos = (flags & 0x06) >> 1
    retain = (flags & 0x01)

    topic = mqtt_read(s, String)

    if qos == 0x01
        id = mqtt_read(s, UInt16)
        write_packet(client, PUBACK, id)
    end

    if qos == 0x02
        id = mqtt_read(s, UInt16)
        write_packet(client, PUBREC, id)
    end

    payload = take!(s)
    @schedule client.on_msg(topic, payload)
end

function handle_ack(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    id = mqtt_read(s, UInt16)
    # TODO move this to its own function
    if haskey(client.in_flight, id)
        future = client.in_flight[id]
        put!(future, nothing)
        delete!(client.in_flight, id)
    else
        # TODO unexpected ack protocol error
    end
end

function handle_pubrec(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    id = mqtt_read(s, UInt16)
    write_packet(client, PUBREL  | 0x02, id)
end

function handle_pubrel(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    id = mqtt_read(s, UInt16)
    write_packet(client, PUBCOMP, id)
end

function handle_suback(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    id = mqtt_read(s, UInt16)
    return_codes = take!(s)
    put!(client.in_flight[id], return_codes)
end

function handle_pingresp(client::Client, s::IO, cmd::UInt8, flags::UInt8)
    if client.ping_outstanding[] == 0x1
      atomic_xchg!(client.ping_outstanding, 0x0)
    else
      # We received a subresp packet we didn't ask for
      disconnect(client)
    end
end

const HANDLERS = Dict{UInt8, Function}(
CONNACK => handle_connack,
PUBLISH => handle_publish,
PUBACK => handle_ack,
PUBREC => handle_pubrec,
PUBREL => handle_pubrel,
PUBCOMP => handle_ack,
SUBACK => handle_suback,
UNSUBACK => handle_ack,
PINGRESP => handle_pingresp
)

# TODO needs mutex
function packet_id(client)
    if client.last_id == typemax(UInt16)
        client.last_id = 0
    end
    client.last_id += 1
    return client.last_id
end

function write_loop(client)
    try
        while isopen(client.socket)
            packet = take_write_packets!(client)
            buffer = PipeBuffer()
            for i in packet.data
                mqtt_write(buffer, i)
            end
            data = take!(buffer)
            lock(client.socket_lock)
            write(client.socket, packet.cmd)
            write_len(client.socket, length(data))
            write(client.socket, data)
            unlock(client.socket_lock)
            atomic_xchg!(client.last_sent, time())
        end
    catch e
        # channel closed
        if isa(e, InvalidStateException)
            close(client.socket)
        else
            rethrow()
        end
    end
end

function read_loop(client)
    try
        while isopen(client.socket)
            cmd_flags = read(client.socket, UInt8)
            len = read_len(client.socket)
            data = read(client.socket, len)
            buffer = PipeBuffer(data)
            cmd = cmd_flags & 0xF0
            flags = cmd_flags & 0x0F

            if haskey(HANDLERS, cmd)
                atomic_xchg!(client.last_received, time())
                HANDLERS[cmd](client, buffer, cmd, flags)
            else
                # TODO unexpected cmd protocol error
            end
        end
    catch e
        # socket closed
        if !isa(e, EOFError)
            rethrow()
        end
    end
end

function keep_alive_loop(client::Client)
    ping_sent = time()

    if client.keep_alive > 10
      check_interval = 5
    else
      check_interval = client.keep_alive / 2
    end
    timer = Timer(0, check_interval)

    while isopen(client.socket)
      if time() - client.last_sent[] >= client.keep_alive || time() - client.last_received[] >= client.keep_alive
        if client.ping_outstanding[] == 0x0
          atomic_xchg!(client.ping_outstanding, 0x1)
          try
            lock(client.socket_lock)
            write(client.socket, PINGREQ)
            write(client.socket, 0x00)
            unlock(client.socket_lock)
            atomic_xchg!(client.last_sent, time())
          catch e
              if isa(e, InvalidStateException)
                  break
                  # TODO is this the socket closed exception? Handle accordingly
              else
                  rethrow()
              end
          end
          ping_sent = time()
        end
      end

      if client.ping_outstanding[] == 1 && time() - ping_sent >= client.ping_timeout
        try # No pingresp received
          disconnect(client)
          break
        catch e
            # channel closed
            if isa(e, InvalidStateException)
                break
            else
                rethrow()
            end
        end
        # TODO automatic reconnect
      end

      wait(timer)
    end
end

function unlock_disconnect_ready(client::Client)
    if length(client.in_flight) == 0 && !isready(client.write_packets)
        client.disconnect_ready = true
        notify(client.disconnect_ready_cond)
    end
end

function lock_disconnect_ready(client::Client)
    client.disconnect_ready = false
end

function delete_in_flight!(client::Client, mid::UInt16)
    delete!(client.in_flight, mid)
    unlock_disconnect_ready(client)
end

function put_in_flight!(client::Client, mid::UInt16, future::Future)
    client.in_flight[mid] = future
    lock_disconnect_ready(client)
end

function put_write_packets!(client::Client, packet::Packet)
    put!(client.write_packets, packet)
    lock_disconnect_ready(client)
end

function take_write_packets!(client::Client)
    packet = take!(client.write_packets)
    unlock_disconnect_ready(client)
    return packet
end 

function write_packet(client::Client, cmd::UInt8, data...)  
    put_write_packets!(client, Packet(cmd, data))
end

# the docs make it sound like fetch would alrdy work in this way
# check julia sources
function get(future)
    r = fetch(future)
    if typeof(r) <: Exception
        throw(r)
    end
    return r
end

#TODO change keep_alive to Int64 and convert ourselves
function connect_async(client::Client, host::AbstractString, port::Integer=1883;
    keep_alive::UInt16=0x0000,
    client_id::String=randstring(8),
    user::User=User("", ""),
    will::Message=Message(false, 0x00, false, "", Array{UInt8}()),
    clean_session::Bool=true)

    client.write_packets = Channel{Packet}(client.write_packets.sz_max)
    client.keep_alive = keep_alive
    client.socket = connect(host, port)
    @schedule write_loop(client)
    @schedule read_loop(client)

    if client.keep_alive > 0x0000
      @schedule keep_alive_loop(client)
    end

    #TODO reset client on clean_session = true

    protocol_name = "MQTT"
    protocol_level = 0x04
    connect_flags = 0x02 # clean session

    optional = ()

    if length(will.topic) > 0
        # TODO
    end

    future = Future()
    put_in_flight!(client, 0x0000, future)

    write_packet(client, CONNECT,
    protocol_name,
    protocol_level,
    connect_flags,
    client.keep_alive,
    client_id,
    optional...)

    return future
end

connect(client::Client, host::AbstractString, port::Integer=1883;
keep_alive::UInt16=0x0000,
client_id::String=randstring(8),
user::User=User("", ""),
will::Message=Message(false, 0x00, false, "", Array{UInt8}()),
clean_session::Bool=true) = get(connect_async(client, host, port, keep_alive=keep_alive, client_id=client_id, user=user, will=will, clean_session=clean_session))

function disconnect(client::Client)
    client.exit_flag = true
    #confirmed_finish = false
    #TODO check if we can verify that there certainly won't be another input packet
    #while !confirmed_finish
        if client.disconnect_ready == false
            println("1")
            wait(client.disconnect_ready_cond)
        end
    #end
    println("2")
    write_packet(client, DISCONNECT)
    #TODO sleep?
        if client.disconnect_ready == false
            wait(client.disconnect_ready_cond)
        end
    close(client.write_packets)
    close(client.socket)
    #wait(client.socket.closenotify)
end

# TODO change topics to Tuple{String, UInt8}
function subscribe_async(client::Client, topics::Tuple{String, QOS}...)
    if client.exit_flag
        throw(InvalidStateException("Client is disconnected"))
    end

    future = Future()
    id = packet_id(client)
    put_in_flight!(client, id, future)
    topic_data = []
    for t in topics
        for data in t
            push!(topic_data, data)
        end
    end
    write_packet(client, SUBSCRIBE | 0x02, id, topic_data...)
    return future
end

subscribe(client::Client, topics::Tuple{String, QOS}...) = get(subscribe_async(client, topics...))

function unsubscribe_async(client::Client, topics::String...)
    if client.exit_flag
        throw(InvalidStateException("Client is disconnected"))
    end

    future = Future()
    id = packet_id(client)
    put_in_flight!(client, id, future)
    topic_data = []
    write_packet(client, UNSUBSCRIBE | 0x02, id, topics...)
    return future
end

unsubscribe(client::Client, topics::String...) = get(unsubscribe_async(client, topics...))

function publish_async(client::Client, message::Message)
    if client.exit_flag
        throw(InvalidStateException("Client is disconnected"))
    end

    future = Future()
    optional = ()
    if message.qos == 0x00
        put!(future, 0)
    elseif message.qos == 0x01 || message.qos == 0x02
        future = Future()
        id = packet_id(client)
        put_in_flight!(client, id, future)
        optional = (id)
    else
        throw(MQTTException("invalid qos"))
    end
    cmd = PUBLISH | ((message.dup & 0x1) << 3) | (message.qos << 1) | message.retain
    write_packet(client, cmd, message.topic, optional..., message.payload)
    return future
end

publish_async(client::Client, topic::String, payload...;
    dup::Bool=false,
    qos::QOS=QOS_0,
    retain::Bool=false) = publish_async(client, Message(dup, convert(UInt8, qos), retain, topic, payload...))

publish(client::Client, topic::String, payload...;
    dup::Bool=false,
    qos::QOS=QOS_0,
    retain::Bool=false) = get(publish_async(client, topic, payload..., dup=dup, qos=qos, retain=retain))
