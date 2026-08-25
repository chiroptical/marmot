-module(protocol).
-moduledoc """

""".

-include_lib("pgo/src/pgo_internal.hrl").
-include_lib("ssl/src/ssl_api.hrl").

-behaviour(marmot_error).

-import_record(marmot_config, [config]).

-export_type([reason/0]).

-type reason() ::
    {prepare_failed, map()}
    | {explain_failed, map()}
    | {connection_desynced, term()}
    | {unexpected_message, term()}
    | {unsupported_socket, module(), term()}
    | {type_server_bootstrap_timeout, pgo:pool()}
    | {pgo_application_start_failed, term()}
    | {connection_refused, string(), integer()}
    | {host_unreachable, string(), integer(), inet:posix()}
    | {connect_timeout, string(), integer(), timeout()}
    | {invalid_password, string()}
    | {database_does_not_exist, string()}
    | {tls_required, string()}
    | {tls_not_supported, string()}
    | {tls_handshake_failed, term()}
    | {connection_rejected, map()}
    | {connection_failed, term()}
    | closed
    | {timeout, binary() | erlang:iovec()}
    | inet:posix()
    | binary().

-export([
    prepare_pool/0,
    prepare_pool/1,
    await_types/1,
    prepare_statement/2,
    explain/2,
    format_error/1
]).

-ifdef(TEST).
-export([set_active/2, with_connection/2, checkout_reason/2, connect_error/2]).
-endif.

-doc """
Start marmot's pgo connection pool from environment variables. Equivalent to
`prepare_pool(marmot_config:from_env())`. See `marmot_config:from_env/0` for
the environment variables read.
""".
-spec prepare_pool() -> ok | {error, reason() | marmot_config:reason()}.
prepare_pool() ->
    maybe
        {ok, Config} ?= marmot_config:from_env(),
        prepare_pool(Config)
    end.

-doc """
Start (or attach to) marmot's pgo connection pool per `Config`.

- `connection = {some, C}`: start `application:ensure_all_started(pgo)`, probe
  the connection once so a failure is reported rather than retried in the
  background, then `pgo:start_pool(Pool, C)`. A pool already started under this
  name is treated as success.
- `connection = none`: the caller already started `Pool`; skip startup.

Either way, waits for `pg_types`' asynchronous type server bootstrap to finish
before returning.
""".
-spec prepare_pool(#config{}) -> ok | {error, reason()}.
prepare_pool(#config{
    pool = Pool, connection = {some, Connection}, connect_timeout = ConnectTimeout
}) ->
    maybe
        ok ?= start_pgo(),
        ok ?= probe(Pool, Connection, ConnectTimeout),
        ok ?= start_pool(Pool, Connection),
        await_types(Pool)
    end;
prepare_pool(#config{connection = none, pool = Pool}) ->
    await_types(Pool).

-spec start_pgo() -> ok | {error, reason()}.
start_pgo() ->
    case application:ensure_all_started(pgo) of
        {ok, _Started} -> ok;
        {error, Reason} -> {error, {pgo_application_start_failed, Reason}}
    end.

-dialyzer({nowarn_function, start_pool/2}).
-spec start_pool(pgo:pool(), marmot_config:connection()) -> ok | {error, term()}.
start_pool(Pool, Connection) ->
    case pgo:start_pool(Pool, Connection) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, _} = Error -> Error
    end.

-spec probe(pgo:pool(), marmot_config:connection(), timeout()) -> ok | {error, reason()}.
probe(Pool, Connection, ConnectTimeout) ->
    case open_probe(Pool, Connection, ConnectTimeout) of
        ok ->
            ok;
        {error, probe_deadline} ->
            {error, {connect_timeout, host(Connection), port(Connection), ConnectTimeout}};
        {error, Reason} ->
            {error, connect_error(Connection, Reason)}
    end.

-spec open_probe(pgo:pool(), marmot_config:connection(), timeout()) -> ok | {error, term()}.
open_probe(Pool, Connection, ConnectTimeout) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! {probe, self(), open_connection(Pool, Connection)}
    end),
    receive
        {probe, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, {probe_crashed, Reason}}
    after ConnectTimeout ->
        erlang:demonitor(Monitor, [flush]),
        exit(Pid, kill),
        {error, probe_deadline}
    end.

-spec open_connection(pgo:pool(), marmot_config:connection()) -> ok | {error, term()}.
open_connection(Pool, Connection) ->
    case pgo_handler:open(Pool, Connection) of
        {ok, Conn} ->
            _ = pgo_handler:close(Conn),
            ok;
        {error, _} = Error ->
            Error
    end.

-spec connect_error(marmot_config:connection(), term()) -> reason().
connect_error(Connection, {pgo_error, #{code := ~"28P01"}}) ->
    {invalid_password, maps:get(user, Connection, "")};
connect_error(Connection, {pgo_error, #{code := ~"3D000"}}) ->
    {database_does_not_exist, maps:get(database, Connection, "")};
connect_error(Connection, {pgo_error, #{code := ~"28000", message := Message} = Fields}) ->
    case binary:match(Message, ~"SSL off") of
        nomatch -> {connection_rejected, Fields};
        _ -> {tls_required, host(Connection)}
    end;
connect_error(_Connection, {pgo_error, Fields}) ->
    {connection_rejected, Fields};
connect_error(Connection, econnrefused) ->
    {connection_refused, host(Connection), port(Connection)};
connect_error(Connection, Posix) when
    Posix =:= ehostunreach; Posix =:= enetunreach; Posix =:= nxdomain; Posix =:= etimedout
->
    {host_unreachable, host(Connection), port(Connection), Posix};
connect_error(Connection, ssl_refused) ->
    {tls_not_supported, host(Connection)};
connect_error(_Connection, Reason) when
    is_tuple(Reason), element(1, Reason) =:= tls_alert orelse element(1, Reason) =:= options
->
    {tls_handshake_failed, Reason};
connect_error(_Connection, {probe_crashed, Reason}) ->
    {connection_failed, Reason};
connect_error(_Connection, Reason) ->
    {connection_failed, Reason}.

-spec host(marmot_config:connection()) -> string().
host(Connection) ->
    maps:get(host, Connection, "127.0.0.1").

-spec port(marmot_config:connection()) -> integer().
port(Connection) ->
    maps:get(port, Connection, 5432).

-spec format_error(reason()) -> binary().
format_error({pgo_application_start_failed, Reason}) ->
    marmot_error:message(
        "the pgo application would not start: ~p. marmot cannot talk to "
        "PostgreSQL without it.",
        [Reason]
    );
format_error({connection_refused, Host, Port}) ->
    marmot_error:message(
        "nothing is listening on ~ts:~p. Check the host and port, and that the "
        "server is running.",
        [Host, Port]
    );
format_error({host_unreachable, Host, Port, Posix}) ->
    marmot_error:message(
        "~ts:~p could not be reached: ~p. Check the host name and that the "
        "network allows the connection.",
        [Host, Port, Posix]
    );
format_error({connect_timeout, Host, Port, ConnectTimeout}) ->
    marmot_error:message(
        "~ts:~p accepted a connection but did not finish the PostgreSQL "
        "handshake within ~pms. A firewall or proxy in front of the database "
        "usually causes this. Raise PGO_CONNECT_TIMEOUT if the server is only "
        "slow.",
        [Host, Port, ConnectTimeout]
    );
format_error({invalid_password, User}) ->
    marmot_error:message(
        "PostgreSQL rejected the password for ~ts. Fix PGO_PASSWORD, or the "
        "password in DATABASE_URL.",
        [User]
    );
format_error({database_does_not_exist, Database}) ->
    marmot_error:message(
        "PostgreSQL has no database named ~ts. Create it, or fix PGO_DATABASE "
        "or the path in DATABASE_URL.",
        [Database]
    );
format_error({tls_required, Host}) ->
    marmot_error:message(
        "~ts refuses connections without TLS. Set PGO_SSLMODE to `verify-full`, "
        "or add `?sslmode=verify-full` to DATABASE_URL.",
        [Host]
    );
format_error({tls_not_supported, Host}) ->
    marmot_error:message(
        "TLS was requested but ~ts does not offer it. Set PGO_SSLMODE to "
        "`disable` if the connection does not need it.",
        [Host]
    );
format_error({tls_handshake_failed, Reason}) ->
    marmot_error:message(
        "the TLS handshake failed: ~p. For a server with a private CA, point "
        "PGO_SSLROOTCERT at its bundle.",
        [Reason]
    );
format_error({connection_rejected, #{message := Message, code := Code}}) ->
    marmot_error:message(
        "PostgreSQL refused the connection: ~ts (SQLSTATE ~ts).", [Message, Code]
    );
format_error({connection_rejected, Fields}) ->
    marmot_error:message("PostgreSQL refused the connection: ~p.", [Fields]);
format_error({connection_failed, Reason}) ->
    marmot_error:message("marmot could not connect: ~p.", [Reason]);
format_error({type_server_bootstrap_timeout, Pool}) ->
    marmot_error:message(
        "pool ~p connected but its pg_types type server never finished loading "
        "the type catalogue. The database may be under load, or the role may "
        "not be able to read pg_type.",
        [Pool]
    );
format_error(Reason) ->
    marmot_error:message("~p", [Reason]).

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
-dialyzer({no_missing_return, [prepare_statement/2, explain/2]}).
-spec prepare_statement(#config{}, binary()) ->
    {ok, [oid()], [#row_description_field{}]} | {error, reason()}.
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

-spec explain(#config{}, binary()) -> {ok, JsonBinary :: binary()} | {error, reason()}.
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
