-module(multi_pool_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-import_record(marmot, [untyped_query, field, typed_query]).
-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    concurrent_inference/1,
    per_pool_type_server/1
]).

-define(STATEMENT, ~"select $1::integer as id, name from mp_left where id = $1").
-define(ITERATIONS, 20).

all() ->
    [concurrent_inference, per_pool_type_server].

init_per_suite(Config) ->
    Base = marmot_config:from_env(),
    Connection = Base#config.connection,
    MarmotConfigA = #config{pool = marmot_a, connection = Connection},
    MarmotConfigB = #config{pool = marmot_b, connection = Connection},
    ok = protocol:prepare_pool(MarmotConfigA),
    ok = protocol:prepare_pool(MarmotConfigB),
    pgo:query("drop table if exists mp_left", [], #{pool => marmot_a}),
    #{command := create} =
        pgo:query(
            "create table mp_left (id int not null, name text)",
            [],
            #{pool => marmot_a}
        ),
    #{command := insert} =
        pgo:query("insert into mp_left (id, name) values (1, 'one')", [], #{pool => marmot_a}),
    [{marmot_config_a, MarmotConfigA}, {marmot_config_b, MarmotConfigB} | Config].

end_per_suite(_Config) ->
    pgo:query("drop table if exists mp_left", [], #{pool => marmot_a}),
    application:stop(pgo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

-doc """
Run the full inference path (`marmot:infer_types/2`) repeatedly on two
independent pools, one process each, concurrently. If pool configuration
were still implicit (e.g. a shared `default` pool), this would either fail
outright or nondeterministically cross-talk between the two processes; with
an explicit `#config{}` threaded through, both should consistently and
independently produce the same correct result.
""".
-spec concurrent_inference(term()) -> ok.
concurrent_inference(Config) ->
    MarmotConfigA = proplists:get_value(marmot_config_a, Config),
    MarmotConfigB = proplists:get_value(marmot_config_b, Config),
    Self = self(),
    PidA = spawn_link(fun() -> Self ! {a, run_iterations(MarmotConfigA)} end),
    PidB = spawn_link(fun() -> Self ! {b, run_iterations(MarmotConfigB)} end),
    ResultsA = receive_result(a, PidA),
    ResultsB = receive_result(b, PidB),
    Expected =
        {ok, [
            #field{identifier = id, type = int},
            #field{identifier = name, type = {option, bit_array}}
        ]},
    [?assertEqual(Expected, R) || R <- ResultsA],
    [?assertEqual(Expected, R) || R <- ResultsB],
    ?assertEqual(ResultsA, ResultsB),
    ok.

receive_result(Tag, Pid) ->
    receive
        {Tag, Results} -> Results
    after 30000 ->
        exit(Pid, kill),
        error({timeout_waiting_for, Tag})
    end.

run_iterations(MarmotConfig) ->
    [run_once(MarmotConfig) || _ <- lists:seq(1, ?ITERATIONS)].

run_once(MarmotConfig) ->
    case marmot:infer_types(MarmotConfig, #untyped_query{file_content = ?STATEMENT}) of
        {ok, #typed_query{params = [int], returns = Returns}} -> {ok, Returns};
        {error, _} = E -> E
    end.

-doc """
`pg_types` runs one type server per pool. Pin that resolving OID 23 against
each of `marmot_a` and `marmot_b` returns a `#type_info{}` tagged with that
pool, proving type resolution really is per-pool and not shared global state.
""".
-spec per_pool_type_server(term()) -> ok.
per_pool_type_server(_Config) ->
    ?assertMatch(#type_info{pool = marmot_a}, pg_types:lookup_type_info(marmot_a, 23)),
    ?assertMatch(#type_info{pool = marmot_b}, pg_types:lookup_type_info(marmot_b, 23)),
    ok.
