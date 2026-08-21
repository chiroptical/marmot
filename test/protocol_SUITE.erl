-module(protocol_SUITE).
-include_lib("eunit/include/eunit.hrl").
-include_lib("pgo/src/pgo_internal.hrl").

-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    parameterless_query/1,
    query_with_parameters/1,
    insert_without_returning/1,
    syntax_error/1,
    notice_during_parse/1,
    pool_usable_after_prepare_failure/1,
    unsupported_socket/1,
    pool_usable_after_desync/1,
    deadline_reason/1
]).

all() ->
    [
        parameterless_query,
        query_with_parameters,
        insert_without_returning,
        syntax_error,
        notice_during_parse,
        pool_usable_after_prepare_failure,
        unsupported_socket,
        pool_usable_after_desync,
        deadline_reason
    ].

parameterless_query(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, [], Fields} = protocol:prepare_statement(MarmotConfig, ~"select 1 as num"),
    ?assertEqual(1, length(Fields)),
    [NumField] = Fields,
    ?assertEqual(~"num", NumField#row_description_field.name),
    ?assertEqual(23, NumField#row_description_field.data_type_oid).

query_with_parameters(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, Params, Fields} =
        protocol:prepare_statement(MarmotConfig, ~"select $1::integer as num, $2::text as label"),
    ?assertEqual([23, 25], Params),
    ?assertEqual(2, length(Fields)),
    [NumField, LabelField] = Fields,
    ?assertEqual(~"num", NumField#row_description_field.name),
    ?assertEqual(23, NumField#row_description_field.data_type_oid),
    ?assertEqual(~"label", LabelField#row_description_field.name),
    ?assertEqual(25, LabelField#row_description_field.data_type_oid).

insert_without_returning(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, Params, Fields} =
        protocol:prepare_statement(
            MarmotConfig, ~"insert into pr_target (id, name) values ($1, $2)"
        ),
    ?assertEqual([23, 25], Params),
    ?assertEqual([], Fields).

syntax_error(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Result = protocol:prepare_statement(MarmotConfig, ~"select from where"),
    ?assertMatch({error, {prepare_failed, #{code := ~"42601"}}}, Result).

notice_during_parse(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    LongName = binary:copy(~"a", 64),
    Statement = <<"select 1 as ", LongName/binary>>,
    {ok, [], Fields} = protocol:prepare_statement(MarmotConfig, Statement),
    ?assertEqual(1, length(Fields)),
    [NumField] = Fields,
    ?assertEqual(binary:copy(~"a", 63), NumField#row_description_field.name).

pool_usable_after_prepare_failure(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    [
        ?assertMatch(
            {error, {prepare_failed, _}},
            protocol:prepare_statement(MarmotConfig, ~"select from where")
        )
     || _ <- lists:seq(1, 5)
    ],
    {ok, [], Fields} = protocol:prepare_statement(MarmotConfig, ~"select 1 as num"),
    ?assertEqual(1, length(Fields)).

unsupported_socket(_Config) ->
    [
        ?assertEqual(
            {error, {unsupported_socket, SocketModule, closed}},
            protocol:set_active(#conn{socket_module = SocketModule, socket = closed}, once)
        )
     || SocketModule <- [gen_tcp, ssl]
    ].

pool_usable_after_desync(Config) ->
    MarmotConfig = #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    ?assertEqual({error, injected}, protocol:with_connection(Pool, fun desync/1)),
    {ok, [], Fields} = protocol:prepare_statement(MarmotConfig, ~"select 1 as num"),
    [NumField] = Fields,
    ?assertEqual(~"num", NumField#row_description_field.name).

desync(#conn{socket_module = SocketModule, socket = Socket}) ->
    ok = SocketModule:send(Socket, [
        pgo_protocol:encode_parse_message("", "select 1 as leftover", []),
        pgo_protocol:encode_describe_message(statement, ""),
        pgo_protocol:encode_sync_message()
    ]),
    {error, {connection_desynced, injected}}.

deadline_reason(_Config) ->
    Holder = ets:new(holder, []),
    PoolRef = {marmot, make_ref(), undefined, Holder},
    ?assertEqual(closed, protocol:checkout_reason(PoolRef, closed)),
    ets:delete(Holder),
    ?assertEqual(checkout_deadline_exceeded, protocol:checkout_reason(PoolRef, closed)).

init_per_suite(Config) ->
    MarmotConfig = #config{pool = Pool} = marmot_config:from_env(),
    ok = protocol:prepare_pool(MarmotConfig),
    ok = protocol:prepare_pool(),
    drop_tables(Pool),
    #{command := create} =
        pgo:query(
            "create table pr_target (id int not null, name text)",
            [],
            #{pool => Pool}
        ),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_tables(Pool),
    application:stop(pgo),
    ok.

drop_tables(Pool) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [pr_target]
    ],
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.
