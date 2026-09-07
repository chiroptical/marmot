-module(marmot_config_tests).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot_config, [config]).

-define(VARIABLES, [
    "PGO_HOST",
    "PGO_PORT",
    "PGO_DATABASE",
    "PGO_USER",
    "PGO_PASSWORD",
    "PGO_POOL_SIZE"
]).

-define(LOCAL, [
    {"PGO_HOST", "127.0.0.1"},
    {"PGO_DATABASE", "marmot"},
    {"PGO_USER", "marmot"},
    {"PGO_PASSWORD", "marmot"}
]).

with_env(Variables, Fun) ->
    Saved = [{Name, os:getenv(Name)} || Name <- ?VARIABLES],
    clear(),
    [true = os:putenv(Name, Value) || {Name, Value} <- Variables],
    try
        Fun()
    after
        clear(),
        [true = os:putenv(Name, Value) || {Name, Value} <- Saved, Value =/= false]
    end.

clear() ->
    [true = os:unsetenv(Name) || Name <- ?VARIABLES],
    ok.

connection(Variables) ->
    with_env(Variables, fun marmot_config:connection_from_env/0).

variables_test() ->
    ?assertEqual(
        {ok, #{
            host => "127.0.0.1",
            port => 5432,
            database => "marmot",
            user => "marmot",
            password => "marmot",
            pool_size => 1
        }},
        connection(?LOCAL)
    ).

missing_every_credential_test() ->
    ?assertEqual(
        {error, {missing_credentials, [database, user, password]}},
        connection([{"PGO_HOST", "127.0.0.1"}])
    ).

missing_one_credential_test() ->
    ?assertEqual(
        {error, {missing_credentials, [password]}},
        connection([{"PGO_DATABASE", "marmot"}, {"PGO_USER", "marmot"}])
    ).

invalid_port_test() ->
    ?assertEqual(
        {error, {invalid_integer_env, "PGO_PORT", "five"}},
        connection([{"PGO_PORT", "five"} | ?LOCAL])
    ).

invalid_pool_size_test() ->
    ?assertEqual(
        {error, {invalid_integer_env, "PGO_POOL_SIZE", "many"}},
        connection([{"PGO_POOL_SIZE", "many"} | ?LOCAL])
    ).

pool_size_test() ->
    {ok, Connection} = connection([{"PGO_POOL_SIZE", "4"} | ?LOCAL]),
    ?assertEqual(4, maps:get(pool_size, Connection)).

from_env_owns_the_marmot_pool_test() ->
    {ok, Config} = with_env(?LOCAL, fun marmot_config:from_env/0),
    ?assertEqual(marmot, Config#config.pool),
    ?assertMatch({some, #{database := "marmot"}}, Config#config.connection).
