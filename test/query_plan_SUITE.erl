-module(query_plan_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-import_record(marmot, [untyped_query]).
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
    {ok, _} = application:ensure_all_started(pgo),
    FixtureConfig = #{
        pool_size => 1,
        host => os:getenv("PGO_HOST", "127.0.0.1"),
        database => os:getenv("PGO_DATABASE", "marmot"),
        user => os:getenv("PGO_USER", "marmot"),
        password => os:getenv("PGO_PASSWORD", "marmot")
    },
    {ok, _} = pgo:start_pool(fixture, FixtureConfig),
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => fixture})
     || N <- [qp_a, qp_b]
    ],
    #{command := create} =
        pgo:query("create table qp_a (id int, name text)", [], #{pool => fixture}),
    #{command := create} =
        pgo:query("create table qp_b (id int, value text)", [], #{pool => fixture}),
    ok = protocol:prepare_pool(),
    ok = wait_for_types(default),
    ok = query_plan:ensure_postgres_version(),
    %% Native record #untyped_query{} is defined in marmot; the defining module
    %% must be loaded before external record construction in test cases.
    {module, marmot} = code:ensure_loaded(marmot),
    Config.

end_per_suite(_Config) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => fixture})
     || N <- [qp_a, qp_b]
    ],
    application:stop(pgo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parameterless_query(_Config) ->
    {ok, #plan{join_type = undefined, output = [~"1", ~"2"], plans = []}} =
        query_plan:from_untyped_query(#untyped_query{file_content = ~"select 1 as a, 2 as b"}).

parameterized_query(_Config) ->
    {ok, #plan{join_type = undefined, output = [~"$1"], plans = []}} =
        query_plan:from_untyped_query(#untyped_query{
            file_content = ~"select $1::integer as a"
        }).

left_join(_Config) ->
    {ok, #plan{join_type = left_join, plans = [_, _ | _]}} =
        query_plan:from_untyped_query(#untyped_query{
            file_content = ~"select a.name, b.value from qp_a a left join qp_b b on a.id = b.id"
        }).

invalid_query(_Config) ->
    {error, _} =
        query_plan:from_untyped_query(#untyped_query{file_content = ~"select from"}).

wait_for_types(Pool) ->
    wait_for_types(Pool, 500).

wait_for_types(_Pool, 0) ->
    error({type_server_bootstrap_timeout, default});
wait_for_types(Pool, N) ->
    case pg_types:lookup_type_info(Pool, 23) of
        unknown_oid ->
            timer:sleep(10),
            wait_for_types(Pool, N - 1);
        #type_info{} ->
            ok
    end.
