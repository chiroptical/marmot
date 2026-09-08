-module(connection_SUITE).
-include_lib("eunit/include/eunit.hrl").

-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    connection_refused/1,
    unknown_database/1,
    wrong_password/1,
    tls_not_supported/1,
    connect_timeout/1
]).

all() ->
    [
        connection_refused,
        unknown_database,
        wrong_password,
        tls_not_supported,
        connect_timeout
    ].

connection_refused(Config) ->
    Port = unused_port(),
    ?assertEqual(
        {error, {connection_refused, "127.0.0.1", Port}},
        prepare(Config, refused, #{host => "127.0.0.1", port => Port})
    ).

unknown_database(Config) ->
    ?assertEqual(
        {error, {database_does_not_exist, "marmot_no_such_database"}},
        prepare(Config, unknown_database, #{database => "marmot_no_such_database"})
    ).

wrong_password(Config) ->
    case prepare(Config, wrong_password, #{password => "not the password"}) of
        {error, {invalid_password, User}} ->
            ?assertEqual(maps:get(user, connection(Config)), User);
        ok ->
            {skip, "server accepts any password, so pg_hba is set to trust"}
    end.

tls_not_supported(Config) ->
    Requested = #{ssl => true, ssl_options => [{verify, verify_none}]},
    case prepare(Config, tls_not_supported, Requested) of
        {error, {tls_not_supported, Host}} ->
            ?assertEqual(maps:get(host, connection(Config)), Host);
        ok ->
            {skip, "server offers TLS"}
    end.

connect_timeout(_Config) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Connection = #{
        host => "127.0.0.1",
        port => Port,
        database => "marmot",
        user => "marmot",
        password => "marmot",
        pool_size => 1,
        ssl => false
    },
    MarmotConfig = marmot_config:new(silent, {some, Connection}, 200),
    try
        ?assertEqual(
            {error, {connect_timeout, "127.0.0.1", Port, 200}},
            protocol:prepare_pool(MarmotConfig)
        )
    after
        gen_tcp:close(Listen)
    end.

init_per_suite(Config) ->
    {ok, MarmotConfig} = marmot_config:from_env(),
    ok = protocol:prepare_pool(MarmotConfig),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(_Config) ->
    application:stop(pgo),
    ok.

connection(Config) ->
    #config{connection = {some, Connection}} = proplists:get_value(marmot_config, Config),
    Connection.

prepare(Config, Pool, Overrides) ->
    Connection = maps:merge(connection(Config), Overrides),
    protocol:prepare_pool(marmot_config:new(Pool, {some, Connection}, 5000)).

unused_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.
