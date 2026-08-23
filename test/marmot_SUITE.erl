-module(marmot_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pgo/src/pgo_internal.hrl").

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
    simple_types/1,
    array_of_int/1,
    array_of_text/1,
    multidimensional_array/1,
    enum_param/1,
    enum_array_param/1,
    enum_mixed/1,
    two_distinct_enums/1,
    same_name_enums_distinct_oids/1,
    enum_tricky_labels/1,
    unknown_oid/1,
    returns_simple/1,
    returns_not_null_column/1,
    returns_nullable_column/1,
    returns_left_join_nullable/1,
    returns_right_join_nullable/1,
    returns_full_join_nullable/1,
    returns_foreign_key_nullability/1,
    returns_select_list_order/1,
    returns_composite_rejected/1,
    returns_cte/1,
    returns_recursive_cte/1,
    returns_cte_insert_returning/1,
    returns_suffix_overrides/1,
    returns_enum/1,
    returns_array/1,
    returns_invalid_column_name/1,
    returns_batched_nullability/1,
    duplicate_output_name_nullability/1,
    aggregate_over_empty_table/1,
    count_over_empty_table/1,
    grouped_aggregate/1,
    infer_types_simple/1,
    infer_types_left_join/1,
    infer_types_enum/1,
    infer_types_non_dml/1,
    infer_types_doc/1
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
        same_name_enums_distinct_oids,
        enum_tricky_labels,
        unknown_oid,
        returns_simple,
        returns_not_null_column,
        returns_nullable_column,
        returns_left_join_nullable,
        returns_right_join_nullable,
        returns_full_join_nullable,
        returns_foreign_key_nullability,
        returns_select_list_order,
        returns_composite_rejected,
        returns_cte,
        returns_recursive_cte,
        returns_cte_insert_returning,
        returns_suffix_overrides,
        returns_enum,
        returns_array,
        returns_invalid_column_name,
        returns_batched_nullability,
        duplicate_output_name_nullability,
        aggregate_over_empty_table,
        count_over_empty_table,
        grouped_aggregate,
        infer_types_simple,
        infer_types_left_join,
        infer_types_enum,
        infer_types_non_dml,
        infer_types_doc
    ].

init_per_suite(Config) ->
    MarmotConfig = #config{pool = Pool} = marmot_config:from_env(),
    ok = protocol:prepare_pool(MarmotConfig),
    drop_tables(Pool),
    [
        pgo:query("drop type if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [mood, color, weird]
    ],
    drop_schemas(Pool),
    #{command := create} =
        pgo:query("create type mood as enum ('happy', 'sad', 'meh')", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create type color as enum ('red', 'green', 'blue')", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create type weird as enum ('a-b', 'not allowed', 'UPPER')", [], #{
            pool => Pool
        }),
    #{command := create} =
        pgo:query("create schema s_a", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create type s_a.status as enum ('draft', 'live')", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create schema s_b", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create type s_b.status as enum ('open', 'closed', 'void')", [], #{
            pool => Pool
        }),
    #{command := create} =
        pgo:query(
            "create table mr_left (id int not null, name text, tally int not null)",
            [],
            #{pool => Pool}
        ),
    #{command := create} =
        pgo:query("create table mr_right (id int not null, value text)", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create table mr_parent (id int not null primary key)", [], #{pool => Pool}),
    #{command := create} =
        pgo:query(
            "create table mr_child (id int not null, "
            "parent_id int not null references mr_parent (id), "
            "maybe_parent_id int references mr_parent (id))",
            [],
            #{pool => Pool}
        ),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    {module, marmot} = code:ensure_loaded(marmot),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_tables(Pool),
    drop_schemas(Pool),
    application:stop(pgo),
    ok.

drop_tables(Pool) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [mr_left, mr_right, mr_child, mr_parent]
    ],
    ok.

drop_schemas(Pool) ->
    [
        pgo:query("drop schema if exists " ++ atom_to_list(N) ++ " cascade", [], #{pool => Pool})
     || N <- [s_a, s_b]
    ],
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

simple_types(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(
            MarmotConfig, ~"select $1::integer, $2::text, $3::uuid, $4::bool"
        ),
    {ok, [int, bit_array, uuid, bool]} = marmot:resolve_parameters(MarmotConfig, ParamOids).

array_of_int(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(MarmotConfig, ~"select $1::integer[]"),
    {ok, [{list, int}]} = marmot:resolve_parameters(MarmotConfig, ParamOids).

array_of_text(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(MarmotConfig, ~"select $1::text[]"),
    {ok, [{list, bit_array}]} = marmot:resolve_parameters(MarmotConfig, ParamOids).

multidimensional_array(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(
        MarmotConfig, ~"select $1::integer[][], $2::integer[][][]"
    ),
    {ok, [{list, int}, {list, int}]} = marmot:resolve_parameters(MarmotConfig, ParamOids).

enum_param(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(MarmotConfig, ~"select $1::mood"),
    {ok, [{enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}]} = marmot:resolve_parameters(
        MarmotConfig, ParamOids
    ).

enum_array_param(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(MarmotConfig, ~"select $1::mood[]"),
    {ok, [{list, {enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}}]} = marmot:resolve_parameters(
        MarmotConfig, ParamOids
    ).

enum_mixed(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(MarmotConfig, ~"select $1::mood, $2::integer, $3::text"),
    {ok, [{enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}, int, bit_array]} =
        marmot:resolve_parameters(MarmotConfig, ParamOids).

two_distinct_enums(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(MarmotConfig, ~"select $1::mood, $2::color"),
    {ok, [
        {enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}},
        {enum, {_, ~"color", [~"red", ~"green", ~"blue"]}}
    ]} =
        marmot:resolve_parameters(MarmotConfig, ParamOids).

same_name_enums_distinct_oids(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} =
        protocol:prepare_statement(MarmotConfig, ~"select $1::s_a.status, $2::s_b.status"),
    {ok, [
        {enum, {OidA, ~"status", [~"draft", ~"live"]}},
        {enum, {OidB, ~"status", [~"open", ~"closed", ~"void"]}}
    ]} =
        marmot:resolve_parameters(MarmotConfig, ParamOids),
    ?assertNotEqual(OidA, OidB).

enum_tricky_labels(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, ParamOids, _Fields} = protocol:prepare_statement(MarmotConfig, ~"select $1::weird"),
    {ok, [{enum, {_, ~"weird", [~"a-b", ~"not allowed", ~"UPPER"]}}]} =
        marmot:resolve_parameters(MarmotConfig, ParamOids).

unknown_oid(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {error, {unsupported_type, ?BOGUS_OID}},
        marmot:resolve_parameters(MarmotConfig, [?BOGUS_OID])
    ).

no_nullables() ->
    sets:new().

returns_for(MarmotConfig, Statement) ->
    {ok, _ParamOids, Fields} = protocol:prepare_statement(MarmotConfig, Statement),
    marmot:resolve_returns(MarmotConfig, Fields, no_nullables()).

returns_with_plan(MarmotConfig, Statement) ->
    {ok, _ParamOids, Fields} = protocol:prepare_statement(MarmotConfig, Statement),
    {ok, Plan} = query_plan:from_untyped_query(MarmotConfig, #untyped_query{
        file_content = Statement
    }),
    marmot:resolve_returns(MarmotConfig, Fields, query_plan:nullables_from_plan(Plan)).

returns_simple(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = a, type = int, assumed_not_null = true},
            #field{identifier = b, type = bit_array, assumed_not_null = true}
        ]},
        returns_for(MarmotConfig, ~"select $1::integer as a, $2::text as b")
    ).

returns_not_null_column(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = id, type = int}]},
        returns_for(MarmotConfig, ~"select id from mr_left")
    ).

returns_nullable_column(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = name, type = {option, bit_array}}]},
        returns_for(MarmotConfig, ~"select name from mr_left")
    ).

returns_left_join_nullable(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = tally, type = int},
            #field{identifier = id, type = {option, int}}
        ]},
        returns_with_plan(
            MarmotConfig, ~"select l.tally, r.id from mr_left l left join mr_right r on l.id = r.id"
        )
    ).

returns_right_join_nullable(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = tally, type = {option, int}},
            #field{identifier = id, type = int}
        ]},
        returns_with_plan(
            MarmotConfig,
            ~"select l.tally, r.id from mr_left l right join mr_right r on l.id = r.id"
        )
    ).

returns_full_join_nullable(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = tally, type = {option, int}},
            #field{identifier = id, type = {option, int}}
        ]},
        returns_with_plan(
            MarmotConfig,
            ~"select l.tally, r.id from mr_left l full join mr_right r on l.id = r.id"
        )
    ).

returns_foreign_key_nullability(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = parent_id, type = int},
            #field{identifier = maybe_parent_id, type = {option, int}}
        ]},
        returns_for(MarmotConfig, ~"select parent_id, maybe_parent_id from mr_child")
    ),
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = int},
            #field{identifier = id, type = int}
        ]},
        returns_with_plan(
            MarmotConfig,
            ~"select c.id, p.id from mr_child c join mr_parent p on c.parent_id = p.id"
        )
    ).

returns_select_list_order(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = tally, type = int},
            #field{identifier = name, type = {option, bit_array}},
            #field{identifier = id, type = int}
        ]},
        returns_for(MarmotConfig, ~"select tally, name, id from mr_left")
    ).

returns_composite_rejected(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {error, {unsupported_type, ~"record"}},
        returns_for(MarmotConfig, ~"select row(1, 2) as r")
    ).

returns_cte(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = int},
            #field{identifier = name, type = {option, bit_array}}
        ]},
        returns_with_plan(
            MarmotConfig,
            ~"with rows as (select id, name from mr_left) select id, name from rows"
        )
    ).

returns_recursive_cte(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = n, type = int, assumed_not_null = true}]},
        returns_with_plan(
            MarmotConfig,
            ~"with recursive counter(n) as (select 1 union all select n + 1 from counter where n < 3) select n from counter"
        )
    ).

returns_cte_insert_returning(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = id, type = int}]},
        returns_with_plan(
            MarmotConfig,
            ~"with inserted as (insert into mr_right (id, value) values ($1, $2) returning id) select id from inserted"
        )
    ).

returns_suffix_overrides(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = bit_array},
            #field{identifier = v, type = {option, int}}
        ]},
        returns_for(MarmotConfig, ~"select name as \"id!\", tally as \"v?\" from mr_left")
    ).

returns_enum(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertMatch(
        {ok, [#field{identifier = m, type = {enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}}]},
        returns_for(MarmotConfig, ~"select $1::mood as m")
    ).

returns_array(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertMatch(
        {ok, [
            #field{identifier = xs, type = {list, int}},
            #field{identifier = ms, type = {list, {enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}}}
        ]},
        returns_for(MarmotConfig, ~"select $1::integer[] as xs, $2::mood[] as ms")
    ).

returns_invalid_column_name(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {error, {invalid_column, ~"Weird Name"}},
        returns_for(MarmotConfig, ~"select 1 as \"Weird Name\"")
    ).

returns_batched_nullability(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, _ParamOids, Fields} =
        protocol:prepare_statement(
            MarmotConfig, ~"select l.id, l.name, l.tally, r.id, r.value from mr_left l, mr_right r"
        ),
    [LeftId, LeftName, LeftTally, RightId, RightValue] = [
        {TableOid, AttrNumber}
     || #row_description_field{table_oid = TableOid, attr_number = AttrNumber} <- Fields
    ],
    {ok, Map} = marmot:nullability_map(MarmotConfig, Fields),
    ?assertEqual(
        #{
            LeftId => true,
            LeftName => false,
            LeftTally => true,
            RightId => true,
            RightValue => false
        },
        Map
    ).

duplicate_output_name_nullability(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = {option, int}},
            #field{identifier = id, type = {option, int}}
        ]},
        returns_with_plan(
            MarmotConfig,
            ~"select r.id, r.id from mr_left l left join mr_right r on l.id = r.id"
        )
    ).

aggregate_over_empty_table(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = max, type = {option, int}}]},
        returns_with_plan(MarmotConfig, ~"select max(id) from mr_left")
    ).

count_over_empty_table(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [#field{identifier = count, type = int, assumed_not_null = true}]},
        returns_with_plan(MarmotConfig, ~"select count(*) from mr_left")
    ).

grouped_aggregate(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {ok, [
            #field{identifier = id, type = int},
            #field{identifier = max, type = {option, int}}
        ]},
        returns_with_plan(MarmotConfig, ~"select id, max(tally) from mr_left group by id")
    ).

infer_types_for(MarmotConfig, Statement) ->
    marmot:infer_types(MarmotConfig, #untyped_query{file_content = Statement}).

infer_types_simple(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, TypedQuery} = infer_types_for(MarmotConfig, ~"select id, name from mr_left"),
    ?assertEqual([], TypedQuery#typed_query.params),
    ?assertEqual(
        [
            #field{identifier = id, type = int},
            #field{identifier = name, type = {option, bit_array}}
        ],
        TypedQuery#typed_query.returns
    ).

infer_types_left_join(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, TypedQuery} = infer_types_for(
        MarmotConfig,
        ~"select l.tally, r.id from mr_left l left join mr_right r on l.id = r.id"
    ),
    ?assertEqual(
        [
            #field{identifier = tally, type = int},
            #field{identifier = id, type = {option, int}}
        ],
        TypedQuery#typed_query.returns
    ).

infer_types_enum(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    {ok, TypedQuery} = infer_types_for(MarmotConfig, ~"select $1::mood as m"),
    ?assertMatch([{enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}], TypedQuery#typed_query.params),
    ?assertMatch(
        [#field{identifier = m, type = {enum, {_, ~"mood", [~"happy", ~"sad", ~"meh"]}}}],
        TypedQuery#typed_query.returns
    ).

infer_types_non_dml(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {error, {non_dml_statement, ~"set"}},
        infer_types_for(MarmotConfig, ~"set search_path to public")
    ).

infer_types_doc(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    UntypedQuery = #untyped_query{
        file_content = ~"select 1 as one",
        doc = [~"a comment"]
    },
    {ok, TypedQuery} = marmot:infer_types(MarmotConfig, UntypedQuery),
    ?assertEqual([~"a comment"], TypedQuery#typed_query.doc).
