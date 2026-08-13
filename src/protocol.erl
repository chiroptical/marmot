-module(protocol).
-moduledoc """

""".

-include_lib("pgo/src/pgo_internal.hrl").

-import_record(marmot_config, [config]).

-export([
    prepare_pool/0,
    prepare_pool/1,
    await_types/1,
    prepare_statement/2,
    explain/2
]).

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
            logger:notice(Reason),
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

## TODO

- Handle errors from `receive_message/4`
""".
-spec prepare_statement(#config{}, binary()) ->
    {ok, [oid()], [#row_description_field{}]} | {error, binary()}.
prepare_statement(#config{pool = Pool}, Statement) ->
    maybe
        {ok, PoolRef, Conn} ?= pgo:checkout(Pool),
        %% pgo's `extended_query` leaves the socket in `{active, once}` for idle
        %% notification monitoring. We use blocking `recv` below, so switch to
        %% `{active, false}` for the duration of the exchange, then restore
        %% `{active, once}` before checkin so pgo resumes its idle handling.
        ok = set_active(Conn, false),
        ok ?= parse(Conn, Statement),
        ok ?= describe(Conn),
        ok ?= sync(Conn),
        {ok, #parse_complete{}} ?= receive_message(Conn, []),
        {ok, #parameter_description{count = _ParamCount, data_types = Params}} ?=
            receive_message(Conn, []),
        {ok, #row_description{count = _RowCount, fields = Fields}} ?=
            receive_message(Conn, []),
        {ok, _} ?= receive_message(Conn, []),
        ok = set_active(Conn, once),
        ok ?= pgo:checkin(PoolRef, Conn),
        {ok, Params, Fields}
    else
        {error, Reason} ->
            logger:notice(Reason),
            {error, ~"Something unexpected happened"}
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
        _ ->
            Result0
    end.

-type send() :: ok | {error, closed | {timeout, binary() | erlang:iovec()} | inet:posix()}.

-doc """
Send a parse message to postgresql    
""".
-spec parse(#conn{}, binary()) -> send().
parse(#conn{socket_module = SocketModule, socket = Socket}, Query) ->
    SocketModule:send(Socket, pgo_protocol:encode_parse_message("", Query, [])).

-doc """
Send a describe message to postgresql    
""".
-spec describe(#conn{}) -> send().
describe(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_describe_message(statement, "")).

-doc """
Send a sync message to postgresql    
""".
-spec sync(#conn{}) -> send().
sync(#conn{socket_module = SocketModule, socket = Socket}) ->
    SocketModule:send(Socket, pgo_protocol:encode_sync_message()).

-spec set_active(#conn{}, false | once | true) -> ok | {error, term()}.
set_active(#conn{socket_module = gen_tcp, socket = Socket}, Mode) when is_port(Socket) ->
    inet:setopts(Socket, [{active, Mode}]);
set_active(#conn{socket_module = ssl, socket = Socket}, Mode) ->
    ssl:setopts(Socket, [{active, Mode}]).

-doc """
Given a SQL query in `binary()` format generate an EXPLAIN PLAN for the query.
""".
-spec explain(#config{}, binary()) -> {ok, JsonBinary :: binary()} | {error, term()}.
explain(#config{pool = Pool}, Query) ->
    maybe
        {ok, PoolRef, Conn} ?= pgo:checkout(Pool),
        try
            ok = set_active(Conn, false),
            run_explain(Conn, Query)
        after
            set_active(Conn, once),
            pgo:checkin(PoolRef, Conn)
        end
    else
        {error, Reason} ->
            logger:notice(Reason),
            {error, ~"Unable to checkout connection"}
    end.

-spec run_explain(#conn{}, binary()) -> {ok, binary()} | {error, term()}.
run_explain(Conn, Query) ->
    case simple_query(Conn, Query) of
        ok -> receive_explain_messages(Conn);
        {error, _} = E -> E
    end.

-spec simple_query(#conn{}, binary()) -> send().
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
