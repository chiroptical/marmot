-module(marmot_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pg_types/include/pg_types.hrl").

name_int2_test() ->
    ?assertEqual({ok, int}, marmot:name_to_type(~"int2")).
name_int4_test() ->
    ?assertEqual({ok, int}, marmot:name_to_type(~"int4")).
name_int8_test() ->
    ?assertEqual({ok, int}, marmot:name_to_type(~"int8")).
name_oid_test() ->
    ?assertEqual({ok, int}, marmot:name_to_type(~"oid")).
name_float4_test() ->
    ?assertEqual({ok, float}, marmot:name_to_type(~"float4")).
name_float8_test() ->
    ?assertEqual({ok, float}, marmot:name_to_type(~"float8")).
name_numeric_test() ->
    ?assertEqual({ok, numeric}, marmot:name_to_type(~"numeric")).
name_bool_test() ->
    ?assertEqual({ok, bool}, marmot:name_to_type(~"bool")).
name_text_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"text")).
name_varchar_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"varchar")).
name_bpchar_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"bpchar")).
name_char_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"char")).
name_name_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"name")).
name_citext_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"citext")).
name_bytea_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"bytea")).
name_bit_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"bit")).
name_varbit_test() ->
    ?assertEqual({ok, bit_array}, marmot:name_to_type(~"varbit")).
name_uuid_test() ->
    ?assertEqual({ok, uuid}, marmot:name_to_type(~"uuid")).
name_json_test() ->
    ?assertEqual({ok, json}, marmot:name_to_type(~"json")).
name_jsonb_test() ->
    ?assertEqual({ok, json}, marmot:name_to_type(~"jsonb")).
name_date_test() ->
    ?assertEqual({ok, date}, marmot:name_to_type(~"date")).
name_time_test() ->
    ?assertEqual({ok, time_of_day}, marmot:name_to_type(~"time")).
name_timestamp_test() ->
    ?assertEqual({ok, timestamp}, marmot:name_to_type(~"timestamp")).
name_timestamptz_test() ->
    ?assertEqual({ok, timestamp}, marmot:name_to_type(~"timestamptz")).
name_unknown_test() ->
    ?assertEqual(
        {error, {unsupported_type, ~"weirdtype"}},
        marmot:name_to_type(~"weirdtype")
    ).

array_of_int_test() ->
    BaseInfo = base_type_info(),
    Info = BaseInfo#type_info{
        module = pg_array,
        name = ~"_int4",
        elem_type = BaseInfo#type_info{module = pg_int4, name = ~"int4"}
    },
    ?assertEqual({ok, {list, int}}, marmot:type_info_to_type(dummy, Info)).

array_of_text_test() ->
    BaseInfo = base_type_info(),
    Info = BaseInfo#type_info{
        module = pg_array,
        name = ~"_text",
        elem_type = BaseInfo#type_info{module = pg_raw, name = ~"text"}
    },
    ?assertEqual({ok, {list, bit_array}}, marmot:type_info_to_type(dummy, Info)).

base_type_info() ->
    #type_info{
        oid = 0,
        module = dummy,
        config = undefined,
        pool = default,
        name = <<>>,
        typsend = <<>>,
        typreceive = <<>>,
        typlen = 0,
        output = <<>>,
        input = <<>>,
        elem_oid = 0,
        elem_type = undefined,
        base_oid = 0,
        comp_oids = [],
        comp_types = undefined
    }.

empty_params_test() ->
    ?assertEqual({ok, []}, marmot:resolve_parameters([])).

collect_all_ok_test() ->
    ?assertEqual({ok, [1, 2, 3]}, marmot_helper:collect([{ok, 1}, {ok, 2}, {ok, 3}])).
collect_short_circuits_test() ->
    ?assertEqual(
        {error, boom},
        marmot_helper:collect([{ok, 1}, {error, boom}, {ok, 3}])
    ).
collect_empty_test() ->
    ?assertEqual({ok, []}, marmot_helper:collect([])).
