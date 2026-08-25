-module(marmot_config_tests).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot_config, [config]).

-define(VARIABLES, [
    "DATABASE_URL",
    "PGO_HOST",
    "PGO_PORT",
    "PGO_DATABASE",
    "PGO_USER",
    "PGO_PASSWORD",
    "PGO_SSLMODE",
    "PGO_SSLROOTCERT",
    "PGO_POOL_SIZE",
    "PGO_CONNECT_TIMEOUT"
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

url_test() ->
    ?assertEqual(
        {ok, #{
            host => "db.example.com",
            port => 6543,
            database => "app",
            user => "reader",
            password => "hunter2",
            pool_size => 1,
            ssl => false
        }},
        connection([{"DATABASE_URL", "postgres://reader:hunter2@db.example.com:6543/app"}])
    ).

url_defaults_the_port_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgresql://u:p@h/app"}]),
    ?assertEqual(5432, maps:get(port, Connection)).

url_percent_decodes_userinfo_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://user%2Bro:p%40ss@h/app%20one"}]),
    ?assertEqual("user+ro", maps:get(user, Connection)),
    ?assertEqual("p@ss", maps:get(password, Connection)),
    ?assertEqual("app one", maps:get(database, Connection)).

url_rejects_other_schemes_test() ->
    ?assertEqual(
        {error, {invalid_database_url, unsupported_scheme}},
        connection([{"DATABASE_URL", "mysql://u:p@h/app"}])
    ).

url_without_a_database_test() ->
    ?assertEqual(
        {error, {invalid_database_url, missing_database}},
        connection([{"DATABASE_URL", "postgres://u:p@h"}])
    ).

url_without_a_password_test() ->
    ?assertEqual(
        {error, {invalid_database_url, missing_password}},
        connection([{"DATABASE_URL", "postgres://u@h/app"}])
    ).

url_without_userinfo_test() ->
    ?assertEqual(
        {error, {invalid_database_url, missing_user}},
        connection([{"DATABASE_URL", "postgres://h/app"}])
    ).

url_sslmode_require_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@h/app?sslmode=require"}]),
    ?assertEqual(true, maps:get(ssl, Connection)),
    ?assertEqual([{verify, verify_none}], maps:get(ssl_options, Connection)).

url_sslmode_verify_full_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@h/app?sslmode=verify-full"}]),
    ?assertEqual(true, maps:get(ssl, Connection)),
    ?assertEqual([], maps:get(ssl_options, Connection)).

url_sslmode_is_validated_test() ->
    ?assertEqual(
        {error, {invalid_sslmode, "prefer"}},
        connection([{"DATABASE_URL", "postgres://u:p@h/app?sslmode=prefer"}])
    ).

variables_test() ->
    ?assertEqual(
        {ok, #{
            host => "127.0.0.1",
            port => 5432,
            database => "marmot",
            user => "marmot",
            password => "marmot",
            pool_size => 1,
            ssl => false
        }},
        connection(?LOCAL)
    ).

variables_sslmode_test() ->
    {ok, Connection} = connection([{"PGO_SSLMODE", "require"} | ?LOCAL]),
    ?assertEqual(true, maps:get(ssl, Connection)).

database_url_wins_over_variables_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@elsewhere/other"} | ?LOCAL]),
    ?assertEqual("elsewhere", maps:get(host, Connection)),
    ?assertEqual("other", maps:get(database, Connection)).

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

pool_size_of_zero_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_POOL_SIZE", 0, 1, 1000}},
        connection([{"PGO_POOL_SIZE", "0"} | ?LOCAL])
    ).

pool_size_above_the_maximum_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_POOL_SIZE", 1001, 1, 1000}},
        connection([{"PGO_POOL_SIZE", "1001"} | ?LOCAL])
    ).

port_out_of_range_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_PORT", 65536, 1, 65535}},
        connection([{"PGO_PORT", "65536"} | ?LOCAL])
    ).

negative_port_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_PORT", -1, 1, 65535}},
        connection([{"PGO_PORT", "-1"} | ?LOCAL])
    ).

url_port_at_the_maximum_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@h:65535/db"}]),
    ?assertEqual(65535, maps:get(port, Connection)).

url_port_above_the_maximum_test() ->
    ?assertEqual(
        {error, {invalid_database_url, {port_out_of_range, 65536}}},
        connection([{"DATABASE_URL", "postgres://u:p@h:65536/db"}])
    ).

url_port_of_zero_test() ->
    ?assertEqual(
        {error, {invalid_database_url, {port_out_of_range, 0}}},
        connection([{"DATABASE_URL", "postgres://u:p@h:0/db"}])
    ).

url_bignum_port_test() ->
    ?assertEqual(
        {error, {invalid_database_url, {port_out_of_range, 99999999999999999999999}}},
        connection([{"DATABASE_URL", "postgres://u:p@h:99999999999999999999999/db"}])
    ).

url_without_a_port_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@h/db"}]),
    ?assertEqual(5432, maps:get(port, Connection)).

url_with_an_empty_port_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:p@h:/db"}]),
    ?assertEqual(5432, maps:get(port, Connection)).

empty_database_is_missing_test() ->
    ?assertEqual(
        {error, {missing_credentials, [database]}},
        connection([{"PGO_DATABASE", ""}, {"PGO_USER", "u"}, {"PGO_PASSWORD", "p"}])
    ).

empty_user_is_missing_test() ->
    ?assertEqual(
        {error, {missing_credentials, [user]}},
        connection([{"PGO_DATABASE", "db"}, {"PGO_USER", ""}, {"PGO_PASSWORD", "p"}])
    ).

empty_host_falls_back_to_the_default_test() ->
    {ok, Connection} = connection([{"PGO_HOST", ""} | ?LOCAL]),
    ?assertEqual("127.0.0.1", maps:get(host, Connection)).

empty_password_is_allowed_test() ->
    {ok, Connection} = connection([{"PGO_DATABASE", "db"}, {"PGO_USER", "u"}, {"PGO_PASSWORD", ""}]),
    ?assertEqual("", maps:get(password, Connection)).

url_empty_user_reports_the_user_test() ->
    ?assertEqual(
        {error, {invalid_database_url, missing_user}},
        connection([{"DATABASE_URL", "postgres://:p@h/db"}])
    ).

url_without_a_password_reports_the_password_test() ->
    ?assertEqual(
        {error, {invalid_database_url, missing_password}},
        connection([{"DATABASE_URL", "postgres://u@h/db"}])
    ).

url_empty_password_is_allowed_test() ->
    {ok, Connection} = connection([{"DATABASE_URL", "postgres://u:@h/db"}]),
    ?assertEqual("", maps:get(password, Connection)).

connect_timeout_defaults_to_five_seconds_test() ->
    {ok, Config} = with_env(?LOCAL, fun marmot_config:from_env/0),
    ?assertEqual(5000, Config#config.connect_timeout).

connect_timeout_is_read_in_seconds_test() ->
    {ok, Config} = with_env([{"PGO_CONNECT_TIMEOUT", "2"} | ?LOCAL], fun marmot_config:from_env/0),
    ?assertEqual(2000, Config#config.connect_timeout).

invalid_connect_timeout_test() ->
    ?assertEqual(
        {error, {invalid_integer_env, "PGO_CONNECT_TIMEOUT", "2s"}},
        with_env([{"PGO_CONNECT_TIMEOUT", "2s"} | ?LOCAL], fun marmot_config:from_env/0)
    ).

connect_timeout_at_the_maximum_test() ->
    {ok, Config} = with_env(
        [{"PGO_CONNECT_TIMEOUT", "100"} | ?LOCAL], fun marmot_config:from_env/0
    ),
    ?assertEqual(100000, Config#config.connect_timeout).

connect_timeout_above_the_maximum_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_CONNECT_TIMEOUT", 101, 1, 100}},
        with_env([{"PGO_CONNECT_TIMEOUT", "101"} | ?LOCAL], fun marmot_config:from_env/0)
    ).

connect_timeout_of_zero_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_CONNECT_TIMEOUT", 0, 1, 100}},
        with_env([{"PGO_CONNECT_TIMEOUT", "0"} | ?LOCAL], fun marmot_config:from_env/0)
    ).

negative_connect_timeout_test() ->
    ?assertEqual(
        {error, {integer_env_out_of_range, "PGO_CONNECT_TIMEOUT", -1, 1, 100}},
        with_env([{"PGO_CONNECT_TIMEOUT", "-1"} | ?LOCAL], fun marmot_config:from_env/0)
    ).

from_env_owns_the_marmot_pool_test() ->
    {ok, Config} = with_env(?LOCAL, fun marmot_config:from_env/0),
    ?assertEqual(marmot, Config#config.pool),
    ?assertMatch({some, #{database := "marmot"}}, Config#config.connection).

ssl_root_cert_test() ->
    Path = write_pem(public_key:pem_encode([{'Certificate', <<1, 2, 3>>, not_encrypted}])),
    {ok, Connection} = connection([
        {"PGO_SSLMODE", "verify-full"}, {"PGO_SSLROOTCERT", Path} | ?LOCAL
    ]),
    ?assertEqual([{cacerts, [<<1, 2, 3>>]}], maps:get(ssl_options, Connection)).

ssl_root_cert_without_certificates_test() ->
    Path = write_pem(~"nothing to see here"),
    ?assertEqual(
        {error, {invalid_ssl_root_cert, Path, no_certificates}},
        connection([{"PGO_SSLMODE", "verify-full"}, {"PGO_SSLROOTCERT", Path} | ?LOCAL])
    ).

missing_ssl_root_cert_test() ->
    Path = filename:join(temporary_directory(), "no-such-bundle.pem"),
    ?assertEqual(
        {error, {invalid_ssl_root_cert, Path, enoent}},
        connection([{"PGO_SSLMODE", "verify-full"}, {"PGO_SSLROOTCERT", Path} | ?LOCAL])
    ).

write_pem(Contents) ->
    Path = filename:join(
        temporary_directory(),
        lists:concat([?MODULE, "-", erlang:unique_integer([positive]), ".pem"])
    ),
    ok = file:write_file(Path, Contents),
    Path.

temporary_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> string:trim(Directory, trailing, "/")
    end.
