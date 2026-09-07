-module(query_plan_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot, [untyped_query]).
-import_record(marmot_config, [config]).
-import_record(query_plan, [plan]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    parameterless_query/1,
    parameterized_query/1,
    left_join/1,
    invalid_query/1
]).

all() ->
    [
        parameterless_query,
        parameterized_query,
        left_join,
        invalid_query
    ].

init_per_suite(Config) ->
    {ok, MarmotConfig} = marmot_config:from_env(),
    #config{pool = Pool} = MarmotConfig,
    ok = protocol:prepare_pool(MarmotConfig),
    drop_tables(Pool),
    #{command := create} =
        pgo:query("create table qp_a (id int, name text)", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create table qp_b (id int, value text)", [], #{pool => Pool}),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    {module, marmot} = code:ensure_loaded(marmot),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_tables(Pool),
    application:stop(pgo),
    ok.

drop_tables(Pool) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [qp_a, qp_b]
    ],
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parameterless_query(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, #plan{join_type = none, output = [~"1", ~"2"], plans = []}} =
        query_plan:from_untyped_query(MarmotConfig, #untyped_query{
            file_content = ~"select 1 as a, 2 as b"
        }).

parameterized_query(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, #plan{join_type = none, output = [~"$1"], plans = []}} =
        query_plan:from_untyped_query(MarmotConfig, #untyped_query{
            file_content = ~"select $1::integer as a"
        }).

left_join(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, #plan{join_type = {some, left_join}, output = Output, plans = [Left, Right]}} =
        query_plan:from_untyped_query(MarmotConfig, #untyped_query{
            file_content = ~"select a.name, b.value from qp_a a left join qp_b b on a.id = b.id"
        }),
    ?assertEqual([~"a.name", ~"b.value"], Output),
    ?assertEqual([~"a.name", ~"a.id"], Left#plan.output),
    ?assertEqual([~"b.value", ~"b.id"], Right#plan.output).

invalid_query(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {error, _} =
        query_plan:from_untyped_query(MarmotConfig, #untyped_query{file_content = ~"select from"}).
