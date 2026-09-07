-module(type_round_trip_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot, [untyped_query]).
-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    integer_types/1,
    oid_type/1,
    floating_types/1,
    boolean_type/1,
    text_types/1,
    binary_types/1,
    json_keeps_bytes_jsonb_normalizes/1,
    temporal_types/1,
    uuid_type/1,
    array_types/1,
    enum_types/1
]).

all() ->
    [
        integer_types,
        oid_type,
        floating_types,
        boolean_type,
        text_types,
        binary_types,
        json_keeps_bytes_jsonb_normalizes,
        temporal_types,
        uuid_type,
        array_types,
        enum_types
    ].

init_per_suite(Config) ->
    {ok, Base} = marmot_config:from_env(),
    MarmotConfig = #config{pool = Pool} = Base#config{pool = default},
    ok = protocol:prepare_pool(MarmotConfig),
    drop_all(Pool),
    #{command := create} =
        pgo:query("create type rt_mood as enum ('happy', 'sad', 'meh')", [], #{pool => Pool}),
    #{command := create} =
        pgo:query(
            "create table rt_vals ("
            "  id int generated always as identity,"
            "  c_int2 int2,"
            "  c_int4 int4,"
            "  c_int8 int8,"
            "  c_oid oid,"
            "  c_float4 float4,"
            "  c_float8 float8,"
            "  c_numeric numeric,"
            "  c_bool bool,"
            "  c_text text,"
            "  c_varchar varchar(10),"
            "  c_bpchar char(5),"
            "  c_char \"char\","
            "  c_name name,"
            "  c_bytea bytea,"
            "  c_bit bit(4),"
            "  c_varbit varbit(8),"
            "  c_uuid uuid,"
            "  c_json json,"
            "  c_jsonb jsonb,"
            "  c_date date,"
            "  c_time time,"
            "  c_timestamp timestamp,"
            "  c_timestamptz timestamptz,"
            "  c_int_array int[],"
            "  c_text_array text[],"
            "  c_mood rt_mood,"
            "  c_mood_array rt_mood[]"
            ")",
            [],
            #{pool => Pool}
        ),
    application:stop(pgo),
    ok = protocol:prepare_pool(MarmotConfig),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    {module, marmot} = code:ensure_loaded(marmot),
    {module, codegen} = code:ensure_loaded(codegen),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_all(Pool),
    application:stop(pgo),
    ok.

drop_all(Pool) ->
    pgo:query("drop table if exists rt_vals", [], #{pool => Pool}),
    pgo:query("drop type if exists rt_mood", [], #{pool => Pool}),
    ok.

-spec generate_and_load(#config{}, atom(), [{string(), binary()}]) -> module().
generate_and_load(MarmotConfig, Module, Statements) ->
    TypedQueries = [
        begin
            {ok, TypedQuery} = marmot:infer_types(MarmotConfig, #untyped_query{
                root_name = RootName,
                file_content = Statement
            }),
            TypedQuery
        end
     || {RootName, Statement} <- Statements
    ],
    {ok, Forms} = codegen:forms(Module, TypedQueries),
    {ok, _, Binary} = compile:forms(Forms, [return_errors]),
    {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
    Module.

-spec round_trip([tuple()], string(), term()) -> term().
round_trip(Config, Column, Value) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Insert = "rt_ins_" ++ Column,
    Select = "rt_sel_" ++ Column,
    Module = generate_and_load(MarmotConfig, list_to_atom("rt_" ++ Column ++ "_sql"), [
        {Insert, iolist_to_binary(["insert into rt_vals (", Column, ") values ($1) returning id"])},
        {Select, iolist_to_binary(["select ", Column, " as v from rt_vals where id = $1"])}
    ]),
    {ok, 1, [Inserted]} = apply(Module, list_to_atom(Insert), [Value]),
    {ok, 1, [Row]} = apply(Module, list_to_atom(Select), [records:get(id, Inserted)]),
    records:get(v, Row).

integer_types(Config) ->
    ?assertEqual({some, 32767}, round_trip(Config, "c_int2", 32767)),
    ?assertEqual({some, 2147483647}, round_trip(Config, "c_int4", 2147483647)),
    ?assertEqual(
        {some, 9223372036854775807},
        round_trip(Config, "c_int8", 9223372036854775807)
    ).

oid_type(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    ?assertEqual(
        {error, {unsupported_type, 26}},
        marmot:infer_types(MarmotConfig, #untyped_query{
            root_name = "rt_oid",
            file_content = ~"select c_oid as v from rt_vals where id = $1"
        })
    ).

floating_types(Config) ->
    ?assertEqual({some, 1.5}, round_trip(Config, "c_float4", 1.5)),
    ?assertEqual({some, 1.5}, round_trip(Config, "c_float8", 1.5)),
    ?assertEqual({some, 1.5}, round_trip(Config, "c_numeric", 1.5)).

boolean_type(Config) ->
    ?assertEqual({some, true}, round_trip(Config, "c_bool", true)).

text_types(Config) ->
    ?assertEqual({some, ~"hello"}, round_trip(Config, "c_text", ~"hello")),
    ?assertEqual({some, ~"hello"}, round_trip(Config, "c_varchar", ~"hello")),
    ?assertEqual({some, ~"ab   "}, round_trip(Config, "c_bpchar", ~"ab")),
    ?assertEqual({some, ~"x"}, round_trip(Config, "c_char", ~"x")),
    ?assertEqual({some, ~"some_name"}, round_trip(Config, "c_name", ~"some_name")).

binary_types(Config) ->
    ?assertEqual({some, <<0, 1, 2, 255>>}, round_trip(Config, "c_bytea", <<0, 1, 2, 255>>)),
    ?assertEqual({some, <<5:4>>}, round_trip(Config, "c_bit", <<5:4>>)),
    ?assertEqual({some, <<1:1>>}, round_trip(Config, "c_varbit", <<1:1>>)).

json_keeps_bytes_jsonb_normalizes(Config) ->
    ?assertEqual(
        {some, ~"{\"a\":  1}"},
        round_trip(Config, "c_json", ~"{\"a\":  1}")
    ),
    ?assertEqual(
        {some, ~"{\"a\": 1}"},
        round_trip(Config, "c_jsonb", ~"{\"a\":  1}")
    ).

temporal_types(Config) ->
    ?assertEqual({some, {2026, 8, 20}}, round_trip(Config, "c_date", {2026, 8, 20})),
    ?assertEqual({some, {13, 45, 0}}, round_trip(Config, "c_time", {13, 45, 0})),
    ?assertEqual(
        {some, {{2026, 8, 20}, {12, 0, 0}}},
        round_trip(Config, "c_timestamp", {{2026, 8, 20}, {12, 0, 0}})
    ),
    ?assertEqual(
        {some, {{2026, 8, 20}, {12, 0, 0}}},
        round_trip(Config, "c_timestamptz", {{2026, 8, 20}, {12, 0, 0}})
    ).

uuid_type(Config) ->
    Id = uuid:get_v4(),
    ?assertEqual({some, Id}, round_trip(Config, "c_uuid", Id)).

array_types(Config) ->
    ?assertEqual({some, [1, 2, 3]}, round_trip(Config, "c_int_array", [1, 2, 3])),
    ?assertEqual({some, [~"a", ~"b"]}, round_trip(Config, "c_text_array", [~"a", ~"b"])).

enum_types(Config) ->
    ?assertEqual({some, happy}, round_trip(Config, "c_mood", happy)),
    ?assertEqual({some, [happy, sad]}, round_trip(Config, "c_mood_array", [happy, sad])).
