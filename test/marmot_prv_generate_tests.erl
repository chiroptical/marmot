-module(marmot_prv_generate_tests).

-include_lib("eunit/include/eunit.hrl").

project_root_paths_test() ->
    {ok, Cwd} = file:get_cwd(),
    Root = filename:join(Cwd, "consumer"),
    {ok, Config} = marmot_prv_generate:config(
        #{
            directories => [<<"src/../src/./sql/">>], search_root => "missing"
        },
        Root
    ),
    ?assertEqual([filename:join(Root, "src/sql")], maps:get(directories, Config)),
    ?assertEqual(filename:join(Root, "missing"), maps:get(search_root, Config)),
    ?assertEqual(5000, maps:get(connect_timeout, Config)),
    ?assertEqual({ok, Cwd}, file:get_cwd()),
    Absolute = filename:join(Cwd, "elsewhere/sql"),
    {ok, AbsoluteConfig} = marmot_prv_generate:config(#{directories => [Absolute]}, Root),
    ?assertEqual([Absolute], maps:get(directories, AbsoluteConfig)).

duplicate_normalized_paths_test() ->
    ?assertEqual(
        {error, duplicate_directories},
        marmot_prv_generate:config(#{directories => ["src/sql", <<"src/../src/sql/">>]}, "/project")
    ).

invalid_configuration_test_() ->
    [
        ?_assertMatch({error, _}, marmot_prv_generate:config(Config, "/project"))
     || Config <- [
            [],
            #{pool => default},
            #{connection => #{}},
            #{unknown => true},
            #{directories => ["src/sql" | invalid]},
            #{directories => "src/sql"},
            #{directories => [<<255>>]},
            #{search_root => <<>>},
            #{search_root => [0]},
            #{target_otp => 0},
            #{connect_timeout => -1},
            #{connect_timeout => 1.5}
        ]
    ].
