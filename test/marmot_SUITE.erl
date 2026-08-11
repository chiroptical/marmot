-module(marmot_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot, [untyped_query, field]).

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
    empty_params/1,
    returns_simple/1,
    returns_not_null_column/1,
    returns_nullable_column/1,
    returns_left_join_nullable/1,
    returns_suffix_overrides/1,
    returns_enum/1,
    returns_array/1,
    returns_invalid_column_name/1,
    returns_batched_nullability/1,
    duplicate_output_name_nullability/1,
    aggregate_over_empty_table/1
]).

-define(BOGUS_OID, 999999999).
-define(TABLES, [mr_left, mr_right]).

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
        empty_params,
        returns_simple,
        returns_not_null_column,
        returns_nullable_column,
        returns_left_join_nullable,
        returns_suffix_overrides,
        returns_enum,
        returns_array,
        returns_invalid_column_name,
        returns_batched_nullability,
        duplicate_output_name_nullability,
        aggregate_over_empty_table
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
    drop_tables(),
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
    #{command := create} =
        pgo:query(
            "create table mr_left (id int not null, name text, tally int not null)",
            [],
            #{pool => fixture}
        ),
    #{command := create} =
        pgo:query("create table mr_right (id int not null, value text)", [], #{pool => fixture}),
    ok = protocol:prepare_pool(),
    ok = marmot_test_helpers:wait_for_types(default),
    ok = query_plan:ensure_postgres_version(),
    {module, marmot} = code:ensure_loaded(marmot),
    Config.

end_per_suite(_Config) ->
    drop_tables(),
    application:stop(pgo),
    ok.

drop_tables() ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => fixture})
     || N <- ?TABLES
    ],
    ok.

init_per_testcase(duplicate_output_name_nullability, _Config) ->
    {skip, "TODO: outputs_index_map/1 collapses duplicate column names"};
init_per_testcase(aggregate_over_empty_table, _Config) ->
    {skip, "TODO: aggregates over zero rows are typed non-null"};
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

no_nullables() ->
    sets:new([{version, 2}]).

returns_for(Statement) ->
    {ok, _ParamOids, Fields} = protocol:prepare_statement(Statement),
    marmot:resolve_returns(Fields, no_nullables()).

returns_with_plan(Statement) ->
    {ok, _ParamOids, Fields} = protocol:prepare_statement(Statement),
    {ok, Plan} = query_plan:from_untyped_query(#untyped_query{file_content = Statement}),
    marmot:resolve_returns(Fields, query_plan:nullables_from_plan(Plan)).

returns_simple(_Config) ->
    ?assertEqual(
        {ok, [
            #field{identifier = a, type = int},
            #field{identifier = b, type = bit_array}
        ]},
        returns_for(~"select $1::integer as a, $2::text as b")
    ).

returns_not_null_column(_Config) ->
    ?assertEqual(
        {ok, [#field{identifier = id, type = int}]},
        returns_for(~"select id from mr_left")
    ).

returns_nullable_column(_Config) ->
    ?assertEqual(
        {ok, [#field{identifier = name, type = {option, bit_array}}]},
        returns_for(~"select name from mr_left")
    ).

returns_left_join_nullable(_Config) ->
    ?assertEqual(
        {ok, [
            #field{identifier = tally, type = int},
            #field{identifier = id, type = {option, int}}
        ]},
        returns_with_plan(
            ~"select l.tally, r.id from mr_left l left join mr_right r on l.id = r.id"
        )
    ).

returns_suffix_overrides(_Config) ->
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = bit_array},
            #field{identifier = v, type = {option, int}}
        ]},
        returns_for(~"select name as \"id!\", tally as \"v?\" from mr_left")
    ).

returns_enum(_Config) ->
    ?assertEqual(
        {ok, [#field{identifier = m, type = {enum, ~"mood", [~"happy", ~"sad", ~"meh"]}}]},
        returns_for(~"select $1::mood as m")
    ).

returns_array(_Config) ->
    ?assertEqual(
        {ok, [
            #field{identifier = xs, type = {list, int}},
            #field{identifier = ms, type = {list, {enum, ~"mood", [~"happy", ~"sad", ~"meh"]}}}
        ]},
        returns_for(~"select $1::integer[] as xs, $2::mood[] as ms")
    ).

returns_invalid_column_name(_Config) ->
    ?assertEqual(
        {error, {invalid_column, ~"Weird Name"}},
        returns_for(~"select 1 as \"Weird Name\"")
    ).

returns_batched_nullability(_Config) ->
    {ok, _ParamOids, Fields} =
        protocol:prepare_statement(
            ~"select l.id, l.name, l.tally, r.id, r.value from mr_left l, mr_right r"
        ),
    {ok, Map} = marmot:nullability_map(Fields),
    ?assertEqual(5, maps:size(Map)),
    ?assertEqual(2, length(lists:uniq([Table || {Table, _} <- maps:keys(Map)]))),
    ?assertEqual(
        [false, false, true, true, true],
        lists:sort(maps:values(Map))
    ).

duplicate_output_name_nullability(_Config) ->
    ?assertEqual(
        {ok, [
            #field{identifier = value, type = {option, bit_array}},
            #field{identifier = value, type = {option, bit_array}}
        ]},
        returns_with_plan(
            ~"select r.value, r.value from mr_left l left join mr_right r on l.id = r.id"
        )
    ).

aggregate_over_empty_table(_Config) ->
    ?assertEqual(
        {ok, [#field{identifier = max, type = {option, int}}]},
        returns_with_plan(~"select max(id) from mr_left")
    ).
