-module(protocol).
-moduledoc """
    
""".

-include_lib("pgo/src/pgo_internal.hrl").

-export([
    prepare_statement/1
]).

-doc """
For example,

```erlang
prepare_statement("select brand, model from cars where year = $1").
```

## TODO

- Pool preperation should happen in an exported function called by our plugin
- Types for this function
- Handle errors from `receive_message/4`
""".
prepare_statement(Statement) ->
    maybe
        {ok, _Started} ?= application:ensure_all_started(pgo),
        {ok, _Pid} ?=
            pgo:start_pool(default, #{
                pool_size => 1, host => "127.0.0.1", database => "postgres", user => "chiroptical"
            }),
        {ok, PoolRef, Conn} ?= pgo:checkout(default),
        ok ?= parse(Conn, Statement),
        ok ?= describe(Conn),
        ok ?= sync(Conn),
        #conn{socket_module = SocketModule, socket = Socket} = Conn,
        {ok, #parse_complete{}} ?= receive_message(SocketModule, Socket, Conn, []),
        {ok, #parameter_description{count = _ParamCount, data_types = Params}} ?=
            receive_message(SocketModule, Socket, Conn, []),
        {ok, #row_description{count = _RowCount, fields = Fields}} ?=
            receive_message(SocketModule, Socket, Conn, []),
        {ok, _} ?= receive_message(SocketModule, Socket, Conn, []),
        ok ?= pgo:checkin(PoolRef, Conn),
        {ok, Params, Fields}
    else
        {error, Reason} ->
            logger:notice(Reason),
            {error, "Something unexpected happened"}
    end.

-define(MESSAGE_HEADER_SIZE, 5).

-doc """
Copied directly from https://github.com/erleans/pgo/blob/36efee8288bebbcfd2bfd9b2c157789a77537c3a/src/pgo_handler.erl#L602-L627
The function isn't exported, but I need to decode in a loop

## TODO

- Add types signature
""".
receive_message(SocketModule, Socket, Conn, DecodeOpts) ->
    Result0 =
        case SocketModule:recv(Socket, ?MESSAGE_HEADER_SIZE) of
            {ok, <<Code:8/integer, Size:32/integer>>} ->
                Payload = Size - 4,
                case Payload of
                    0 ->
                        pgo_protocol:decode_message(Code, <<>>, Conn, DecodeOpts);
                    _ ->
                        case SocketModule:recv(Socket, Payload) of
                            {ok, Rest} ->
                                pgo_protocol:decode_message(Code, Rest, Conn, DecodeOpts);
                            {error, _} = ErrorRecvPacket ->
                                ErrorRecvPacket
                        end
                end;
            {error, _} = ErrorRecvPacketHeader ->
                ErrorRecvPacketHeader
        end,
    case Result0 of
        {ok, #notification_response{} = _Notification} ->
            receive_message(SocketModule, Socket, Conn, DecodeOpts);
        _ ->
            Result0
    end.

-doc """
Send a parse message to postgresql    

# TODO

- Add a type signature
""".
parse(#conn{socket_module = SocketModule, socket = Socket}, Query) ->
    SocketModule:send(Socket, pgo_protocol:encode_parse_message("", Query, [])).

-doc """
Send a describe message to postgresql    

## TODO

- Add a type signature
""".
describe(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_describe_message(statement, "")).

-doc """
Send a sync message to postgresql    

## TODO

- Add a type signature
""".
sync(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_sync_message()).
