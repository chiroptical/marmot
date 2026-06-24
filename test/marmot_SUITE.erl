-module(marmot_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    simple_types/1,
    array_of_int/1,
    array_of_text/1,
    multidimensional_array/1,
    enum_param/1,
    enum_array_param/1,
    enum_mixed/1,
    two_distinct_enums/1,
    enum_tricky_labels/1,
    enum_resolve_deterministic/1,
    unknown_oid/1,
    empty_params/1
]).

-define(BOGUS_OID, 999999999).

all() ->
    [
        simple_types,
        array_of_int,
        array_of_text,
        multidimensional_array,
        enum_param,
        enum_array_param,
        enum_mixed,
        two_distinct_enums,
        enum_tricky_labels,
        enum_resolve_deterministic,
        unknown_oid,
        empty_params
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
        pgo:query("drop type if exists " ++ atom_to_list(N), [], #{pool => fixture})
     || N <- [mood, color, weird]
    ],
    #{command := create} =
        pgo:query("create type mood as enum ('happy', 'sad', 'meh')", [], #{pool => fixture}),
    #{command := create} =
        pgo:query("create type color as enum ('red', 'green', 'blue')", [], #{pool => fixture}),
    #{command := create} =
        pgo:query("create type weird as enum ('a-b', 'not allowed', 'UPPER')", [], #{
            pool => fixture
        }),
    ok = protocol:prepare_pool(),
    ok = wait_for_types(default),
    Config.

end_per_suite(_Config) ->
    application:stop(pgo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

simple_types(_Config) ->
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(~"select $1::integer, $2::text, $3::uuid, $4::bool"),
    {ok, [int, bit_array, uuid, bool]} = marmot:resolve_parameters(ParamOids).

array_of_int(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::integer[]"),
    {ok, [{list, int}]} = marmot:resolve_parameters(ParamOids).

array_of_text(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::text[]"),
    {ok, [{list, bit_array}]} = marmot:resolve_parameters(ParamOids).

multidimensional_array(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(
        ~"select $1::integer[][], $2::integer[][][]"
    ),
    {ok, [{list, int}, {list, int}]} = marmot:resolve_parameters(ParamOids).

enum_param(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::mood"),
    {ok, [{enum, ~"mood", [~"happy", ~"sad", ~"meh"]}]} = marmot:resolve_parameters(ParamOids).

enum_array_param(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::mood[]"),
    {ok, [{list, {enum, ~"mood", [~"happy", ~"sad", ~"meh"]}}]} = marmot:resolve_parameters(
        ParamOids
    ).

enum_mixed(_Config) ->
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(~"select $1::mood, $2::integer, $3::text"),
    {ok, [{enum, ~"mood", [~"happy", ~"sad", ~"meh"]}, int, bit_array]} =
        marmot:resolve_parameters(ParamOids).

two_distinct_enums(_Config) ->
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(~"select $1::mood, $2::color"),
    {ok, [
        {enum, ~"mood", [~"happy", ~"sad", ~"meh"]}, {enum, ~"color", [~"red", ~"green", ~"blue"]}
    ]} =
        marmot:resolve_parameters(ParamOids).

enum_tricky_labels(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::weird"),
    {ok, [{enum, ~"weird", [~"a-b", ~"not allowed", ~"UPPER"]}]} =
        marmot:resolve_parameters(ParamOids).

enum_resolve_deterministic(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select $1::mood"),
    First = marmot:resolve_parameters(ParamOids),
    Second = marmot:resolve_parameters(ParamOids),
    ?assertEqual({ok, [{enum, ~"mood", [~"happy", ~"sad", ~"meh"]}]}, First),
    ?assertEqual(First, Second).

unknown_oid(_Config) ->
    ?assertEqual(
        {error, {unsupported_type, ?BOGUS_OID}},
        marmot:resolve_parameters([?BOGUS_OID])
    ).

empty_params(_Config) ->
    {ok, ParamOids, _Fields} = protocol:prepare_statement(~"select 1"),
    {ok, []} = marmot:resolve_parameters(ParamOids).

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
