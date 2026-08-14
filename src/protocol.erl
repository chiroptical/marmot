-module(protocol).
-moduledoc """

""".

-include_lib("pgo/src/pgo_internal.hrl").
-include_lib("ssl/src/ssl_api.hrl").

-import_record(marmot_config, [config]).

-export([
    prepare_pool/0,
    prepare_pool/1,
    await_types/1,
    prepare_statement/2,
    explain/2
]).

-ifdef(TEST).
-export([set_active/2, with_connection/2, checkout_reason/2]).
-endif.

-doc """
Start marmot's pgo connection pool from environment variables. Equivalent to
`prepare_pool(marmot_config:from_env())`. See `marmot_config:from_env/0` for
the environment variables read and their defaults.
""".
-spec prepare_pool() -> ok | {error, term()}.
prepare_pool() ->
    prepare_pool(marmot_config:from_env()).

-doc """
Start (or attach to) marmot's pgo connection pool per `Config`.

- `connection = {some, C}`: start `application:ensure_all_started(pgo)` then
  `pgo:start_pool(Pool, C)`. A pool already started under this name is treated
  as success.
- `connection = none`: the caller already started `Pool`; skip startup.

Either way, waits for `pg_types`' asynchronous type server bootstrap to finish
before returning.
""".
-spec prepare_pool(#config{}) -> ok | {error, term()}.
prepare_pool(#config{pool = Pool, connection = {some, Connection}}) ->
    maybe
        {ok, _Started} ?= application:ensure_all_started(pgo),
        ok ?= start_pool(Pool, Connection),
        await_types(Pool)
    else
        {error, Reason} ->
            logger:notice("unable to start connection pool: ~p", [Reason]),
            {error, ~"Unable to start connection pool"}
    end;
prepare_pool(#config{connection = none, pool = Pool}) ->
    await_types(Pool).

-dialyzer({nowarn_function, start_pool/2}).
-spec start_pool(pgo:pool(), pgo:pool_config()) -> ok | {error, term()}.
start_pool(Pool, Connection) ->
    case pgo:start_pool(Pool, Connection) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, _} = Error -> Error
    end.

-define(TYPE_WAIT_ATTEMPTS, 500).
-define(TYPE_WAIT_SLEEP_MS, 10).

-doc """
Block until `Pool`'s `pg_types` type server has bootstrapped, i.e. until OID
23 (`int4`) resolves. `pg_types` bootstraps its type server asynchronously
after a pool starts, so callers that query it immediately can otherwise race
it. Bounded to `?TYPE_WAIT_ATTEMPTS` attempts, `?TYPE_WAIT_SLEEP_MS` apart.
""".
-spec await_types(pgo:pool()) -> ok | {error, {type_server_bootstrap_timeout, pgo:pool()}}.
await_types(Pool) ->
    await_types(Pool, ?TYPE_WAIT_ATTEMPTS).

-spec await_types(pgo:pool(), non_neg_integer()) ->
    ok | {error, {type_server_bootstrap_timeout, pgo:pool()}}.
await_types(Pool, 0) ->
    {error, {type_server_bootstrap_timeout, Pool}};
await_types(Pool, N) ->
    case pg_types:lookup_type_info(Pool, 23) of
        unknown_oid ->
            timer:sleep(?TYPE_WAIT_SLEEP_MS),
            await_types(Pool, N - 1);
        _ ->
            ok
    end.

-doc """
Prepare and describe a SQL statement, returning the parameter OIDs and row
description fields. Requires that `prepare_pool/1` has been called first for
`Config`'s pool.

For example,

```erlang
{ok, [23], Fields} = protocol:prepare_statement(Config, ~"select $1::integer as num").
```
""".
-spec prepare_statement(#config{}, binary()) ->
    {ok, [oid()], [#row_description_field{}]} | {error, term()}.
prepare_statement(#config{pool = Pool}, Statement) ->
    with_connection(Pool, fun(Conn) -> run_prepare_statement(Conn, Statement) end).

-spec run_prepare_statement(#conn{}, binary()) ->
    {ok, [oid()], [#row_description_field{}]} | {error, term()}.
run_prepare_statement(Conn, Statement) ->
    maybe
        ok ?= sent(parse(Conn, Statement)),
        ok ?= sent(describe(Conn)),
        ok ?= sent(sync(Conn)),
        ok ?= receive_parse_complete(Conn),
        {ok, #parameter_description{count = _ParamCount, data_types = Params}} ?=
            receive_message(Conn, []),
        {ok, Fields} ?= receive_row_description_or_no_data(Conn),
        {ok, _} ?= receive_message(Conn, []),
        {ok, Params, Fields}
    else
        {error, {prepare_failed, _}} = PrepareFailed ->
            PrepareFailed;
        {error, {connection_desynced, _}} = Desynced ->
            Desynced;
        {error, Reason} ->
            logger:notice("unexpected failure preparing statement: ~p", [Reason]),
            {error, ~"Something unexpected happened"}
    end.

-spec receive_parse_complete(#conn{}) -> ok | {error, term()}.
receive_parse_complete(Conn) ->
    case receive_message(Conn, []) of
        {ok, #parse_complete{}} ->
            ok;
        {ok, #error_response{fields = Fields}} ->
            drain_until_ready(Conn),
            {error, {prepare_failed, Fields}};
        {ok, Other} ->
            drain_until_ready(Conn),
            {error, {unexpected_message, Other}};
        {error, _} = E ->
            E
    end.

-spec receive_row_description_or_no_data(#conn{}) ->
    {ok, [#row_description_field{}]} | {error, term()}.
receive_row_description_or_no_data(Conn) ->
    case receive_message(Conn, []) of
        {ok, #row_description{count = _RowCount, fields = Fields}} ->
            {ok, Fields};
        {ok, #no_data{}} ->
            {ok, []};
        {ok, #error_response{fields = Fields}} ->
            drain_until_ready(Conn),
            {error, {prepare_failed, Fields}};
        {ok, Other} ->
            drain_until_ready(Conn),
            {error, {unexpected_message, Other}};
        {error, _} = E ->
            E
    end.

-define(MESSAGE_HEADER_SIZE, 5).

-doc """
Copied directly from https://github.com/erleans/pgo/blob/36efee8288bebbcfd2bfd9b2c157789a77537c3a/src/pgo_handler.erl#L602-L627
The function isn't exported, but I need to decode in a loop
""".
-spec receive_message(#conn{}, list()) -> {ok, _} | {error, any()}.
receive_message(#conn{socket_module = SocketModule, socket = Socket} = Conn, DecodeOpts) ->
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
            receive_message(Conn, DecodeOpts);
        {ok, #notice_response{} = _Notice} ->
            receive_message(Conn, DecodeOpts);
        _ ->
            Result0
    end.

-type gen_tcp_send_return() ::
    ok | {error, closed | {timeout, binary() | erlang:iovec()} | inet:posix()}.

-doc """
Send a parse message to postgresql    
""".
-spec parse(#conn{}, binary()) -> gen_tcp_send_return().
parse(#conn{socket_module = SocketModule, socket = Socket}, Query) ->
    SocketModule:send(Socket, pgo_protocol:encode_parse_message("", Query, [])).

-doc """
Send a describe message to postgresql    
""".
-spec describe(#conn{}) -> gen_tcp_send_return().
describe(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_describe_message(statement, "")).

-doc """
Send a sync message to postgresql    
""".
-spec sync(#conn{}) -> gen_tcp_send_return().
sync(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_sync_message()).

-spec set_active(#conn{}, false | once | true) -> ok | {error, term()}.
set_active(#conn{socket_module = gen_tcp, socket = Socket}, Mode) when is_port(Socket) ->
    inet:setopts(Socket, [{active, Mode}]);
set_active(#conn{socket_module = ssl, socket = #sslsocket{} = Socket}, Mode) ->
    ssl:setopts(Socket, [{active, Mode}]);
set_active(#conn{socket_module = SocketModule, socket = Socket}, _Mode) ->
    {error, {unsupported_socket, SocketModule, Socket}}.

-spec with_connection(pgo:pool(), fun((#conn{}) -> Result)) -> Result | {error, term()}.
with_connection(Pool, Exchange) ->
    maybe
        {ok, PoolRef, Conn} ?= pgo:checkout(Pool),
        try
            ok = set_active(Conn, false),
            Exchange(Conn)
        of
            {error, {connection_desynced, Reason}} ->
                Desynced = checkout_reason(PoolRef, Reason),
                discard_connection(PoolRef, Conn, Desynced),
                {error, Desynced};
            Result ->
                release_connection(PoolRef, Conn),
                Result
        catch
            Class:Reason:Stacktrace ->
                discard_connection(PoolRef, Conn, Reason),
                erlang:raise(Class, Reason, Stacktrace)
        end
    else
        {error, CheckoutReason} ->
            logger:notice("unable to checkout connection: ~p", [CheckoutReason]),
            {error, ~"Unable to checkout connection"}
    end.

-spec release_connection(pgo_pool:ref(), #conn{}) -> ok.
release_connection(PoolRef, Conn) ->
    case set_active(Conn, once) of
        ok ->
            pgo:checkin(PoolRef, Conn);
        {error, Reason} ->
            discard_connection(PoolRef, Conn, Reason)
    end.

-spec checkout_reason(pgo_pool:ref(), term()) -> term().
checkout_reason({_Pool, _Ref, _Deadline, Holder}, Reason) ->
    case ets:info(Holder, size) of
        undefined -> checkout_deadline_exceeded;
        _ -> Reason
    end.

-spec discard_connection(pgo_pool:ref(), #conn{}, term()) -> ok.
discard_connection(PoolRef, Conn, Reason) ->
    logger:notice("discarding connection: ~p", [Reason]),
    pgo_pool:disconnect(PoolRef, {error, connection_desynced}, Conn, []).

-spec sent(gen_tcp_send_return()) -> ok | {error, {connection_desynced, term()}}.
sent(ok) ->
    ok;
sent({error, Reason}) ->
    {error, {connection_desynced, Reason}}.

-spec explain(#config{}, binary()) -> {ok, JsonBinary :: binary()} | {error, term()}.
explain(#config{pool = Pool}, Query) ->
    with_connection(Pool, fun(Conn) -> run_explain(Conn, Query) end).

-spec run_explain(#conn{}, binary()) -> {ok, binary()} | {error, term()}.
run_explain(Conn, Query) ->
    case sent(simple_query(Conn, Query)) of
        ok -> receive_explain_messages(Conn);
        {error, _} = E -> E
    end.

-spec simple_query(#conn{}, binary()) -> gen_tcp_send_return().
simple_query(#conn{socket_module = SocketModule, socket = Socket}, Query) ->
    SocketModule:send(Socket, pgo_protocol:encode_query_message(Query)).

-spec receive_explain_messages(#conn{}) -> {ok, binary()} | {error, term()}.
receive_explain_messages(Conn) ->
    case receive_message(Conn, []) of
        {ok, #error_response{fields = Fields}} ->
            drain_until_ready(Conn),
            {error, {explain_failed, Fields}};
        {ok, #row_description{fields = [#row_description_field{name = ~"QUERY PLAN"}]}} ->
            receive_explain_row(Conn);
        {ok, Other} ->
            drain_until_ready(Conn),
            {error, {unexpected_message, Other}};
        {error, _} = E ->
            E
    end.

-spec receive_explain_row(#conn{}) -> {ok, binary()} | {error, term()}.
receive_explain_row(Conn) ->
    case receive_message(Conn, []) of
        {ok, #data_row{values = [Json]}} ->
            drain_until_ready(Conn),
            {ok, Json};
        {ok, Other} ->
            drain_until_ready(Conn),
            {error, {unexpected_message, Other}};
        {error, _} = E ->
            E
    end.

-spec drain_until_ready(#conn{}) -> ok.
drain_until_ready(Conn) ->
    case receive_message(Conn, []) of
        {ok, #ready_for_query{}} ->
            ok;
        {ok, _} ->
            drain_until_ready(Conn);
        {error, _} ->
            ok
    end.
