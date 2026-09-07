-module(generator_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    generates_modules/1,
    zero_config_scan/1,
    no_query_directories/1,
    aggregates_errors/1,
    one_failing_query_does_not_change_another/1,
    refuses_to_overwrite/1,
    regenerates_deterministically/1,
    starts_and_stops_its_own_pool/1,
    keeps_a_caller_owned_pool/1
]).

-define(TEST_POOL, marmot_generator_suite).

all() ->
    [
        generates_modules,
        zero_config_scan,
        no_query_directories,
        aggregates_errors,
        one_failing_query_does_not_change_another,
        refuses_to_overwrite,
        regenerates_deterministically,
        starts_and_stops_its_own_pool,
        keeps_a_caller_owned_pool
    ].

init_per_suite(Config) ->
    {ok, MarmotConfig} = marmot_config:from_env(),
    #config{pool = Pool} = MarmotConfig,
    ok = protocol:prepare_pool(MarmotConfig),
    drop_tables(Pool),
    #{command := create} =
        pgo:query("create table gen_users (id int not null, name text)", [], #{pool => Pool}),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_tables(Pool),
    application:stop(pgo),
    ok.

drop_tables(Pool) ->
    pgo:query("drop table if exists gen_users", [], #{pool => Pool}),
    ok.

init_per_testcase(TestCase, Config) ->
    Base = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(TestCase)),
    ok = filelib:ensure_path(filename:join(Base, "src")),
    [{base, Base} | Config].

end_per_testcase(_TestCase, Config) ->
    Config.

-spec queries(list(), [{string(), binary()}]) -> string().
queries(Config, Files) ->
    Base = proplists:get_value(base, Config),
    [
        begin
            Full = filename:join(Base, Path),
            ok = filelib:ensure_dir(Full),
            ok = file:write_file(Full, Content)
        end
     || {Path, Content} <- Files
    ],
    Base.

-spec pool(list()) -> pgo:pool().
pool(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    Pool.

-spec connection(list()) -> pgo:pool_config().
connection(Config) ->
    #config{connection = {some, Connection}} = proplists:get_value(marmot_config, Config),
    Connection.

-spec assert_generated(string()) -> module().
assert_generated(Output) ->
    {ok, Module, _Binary} = compile:file(Output, [binary, return_errors]),
    Module.

-define(GET_USER, ~"-- Get a user by id.\nselect id, name from gen_users where id = $1").
-define(LIST_USERS, ~"select id, name from gen_users").
-define(PURGE, ~"delete from gen_users where id = $1").

generates_modules(Config) ->
    Base = queries(Config, [
        {"src/gen_sql/get_user.sql", ?GET_USER},
        {"src/gen_sql/list_users.sql", ?LIST_USERS},
        {"src/gen_sql/admin/purge.sql", ?PURGE}
    ]),
    ok = marmot:generate(#{
        directories => [filename:join(Base, "src/gen_sql")], pool => pool(Config)
    }),
    ?assertEqual(gen_sql, assert_generated(filename:join(Base, "src/gen_sql.erl"))),
    ?assertEqual(gen_sql_admin, assert_generated(filename:join(Base, "src/gen_sql_admin.erl"))),
    ?assertEqual(false, filelib:is_regular(filename:join(Base, "src/gen_sql/admin.erl"))).

zero_config_scan(Config) ->
    Base = queries(Config, [
        {"src/gen_sql/get_user.sql", ?GET_USER},
        {"src/gen_sql/admin/purge.sql", ?PURGE}
    ]),
    ok = marmot:generate(#{
        search_root => filename:join(Base, "src"), pool => pool(Config)
    }),
    ?assertEqual(gen_sql, assert_generated(filename:join(Base, "src/gen_sql.erl"))),
    ?assertEqual(gen_sql_admin, assert_generated(filename:join(Base, "src/gen_sql_admin.erl"))).

no_query_directories(Config) ->
    Base = queries(Config, [{"src/notes/README.md", ~"nothing here\n"}]),
    ok = marmot:generate(#{search_root => filename:join(Base, "src"), pool => pool(Config)}),
    ?assertEqual([], filelib:wildcard(filename:join(Base, "src/*.erl"))).

aggregates_errors(Config) ->
    Base = queries(Config, [
        {"src/gen_sql/get_user.sql", ?GET_USER},
        {"src/gen_sql/unaliased.sql", ~"select id + 1 from gen_users"},
        {"src/gen_sql/session.sql", ~"set search_path to public"},
        {"src/gen_sql/Get-Order.sql", ~"select id from gen_users"}
    ]),
    {error, Errors} = marmot:generate(#{
        directories => [filename:join(Base, "src/gen_sql")], pool => pool(Config)
    }),
    ?assertEqual(
        [
            {
                filename:join(Base, "src/gen_sql/Get-Order.sql"),
                marmot,
                {invalid_query_file_name, "Get-Order"}
            },
            {filename:join(Base, "src/gen_sql/session.sql"), marmot, {non_dml_statement, ~"set"}},
            {
                filename:join(Base, "src/gen_sql/unaliased.sql"),
                marmot,
                {unaliased_expression_column, ~"?column?"}
            }
        ],
        lists:sort(Errors)
    ),
    ?assertEqual(false, filelib:is_regular(filename:join(Base, "src/gen_sql.erl"))).

refuses_to_overwrite(Config) ->
    Base = queries(Config, [{"src/gen_sql/get_user.sql", ?GET_USER}]),
    Output = filename:join(Base, "src/gen_sql.erl"),
    HandWritten = ~"-module(gen_sql).\n",
    ok = file:write_file(Output, HandWritten),
    ?assertEqual(
        {error, [{Output, generator, {refusing_to_overwrite, Output}}]},
        marmot:generate(#{
            directories => [filename:join(Base, "src/gen_sql")], pool => pool(Config)
        })
    ),
    ?assertEqual({ok, HandWritten}, file:read_file(Output)).

regenerates_deterministically(Config) ->
    Base = queries(Config, [
        {"src/gen_sql/get_user.sql", ?GET_USER},
        {"src/gen_sql/list_users.sql", ?LIST_USERS}
    ]),
    Directories = [filename:join(Base, "src/gen_sql")],
    Output = filename:join(Base, "src/gen_sql.erl"),
    ok = marmot:generate(#{directories => Directories, pool => pool(Config)}),
    {ok, First} = file:read_file(Output),
    ok = marmot:generate(#{directories => Directories, pool => pool(Config)}),
    {ok, Second} = file:read_file(Output),
    ?assertEqual(First, Second).

starts_and_stops_its_own_pool(Config) ->
    Base = queries(Config, [{"src/gen_sql/get_user.sql", ?GET_USER}]),
    ?assertEqual(undefined, whereis(?TEST_POOL)),
    ok = marmot:generate(#{
        directories => [filename:join(Base, "src/gen_sql")],
        pool => ?TEST_POOL,
        connection => connection(Config)
    }),
    ?assertEqual(gen_sql, assert_generated(filename:join(Base, "src/gen_sql.erl"))),
    ?assertEqual(undefined, whereis(?TEST_POOL)).

keeps_a_caller_owned_pool(Config) ->
    Base = queries(Config, [{"src/gen_sql/get_user.sql", ?GET_USER}]),
    Pool = pool(Config),
    ok = marmot:generate(#{directories => [filename:join(Base, "src/gen_sql")], pool => Pool}),
    ?assert(is_pid(whereis(Pool))).

one_failing_query_does_not_change_another(Config) ->
    Alone = queries(Config, [{"alone/gen_sql/session.sql", ~"set search_path to public"}]),
    {error, [AloneError]} = marmot:generate(#{
        directories => [filename:join(Alone, "alone/gen_sql")], pool => pool(Config)
    }),
    Together = queries(Config, [
        {"together/gen_sql/session.sql", ~"set search_path to public"},
        {"together/gen_sql/unaliased.sql", ~"select id + 1 from gen_users"}
    ]),
    {error, Errors} = marmot:generate(#{
        directories => [filename:join(Together, "together/gen_sql")], pool => pool(Config)
    }),
    ?assertEqual(2, length(Errors)),
    {_AloneFile, AloneModule, AloneReason} = AloneError,
    [{_File, Module, Reason}] = [
        E
     || {F, _, _} = E <- Errors, filename:basename(F) =:= "session.sql"
    ],
    ?assertEqual({AloneModule, AloneReason}, {Module, Reason}).
