-module(marmot_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-import_record(marmot_config, [config]).

config() ->
    {module, marmot_config} = code:ensure_loaded(marmot_config),
    #config{}.

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
    MarmotConfig = config(),
    BaseInfo = base_type_info(),
    Info = BaseInfo#type_info{
        module = pg_array,
        name = ~"_int4",
        elem_type = BaseInfo#type_info{module = pg_int4, name = ~"int4"}
    },
    ?assertEqual({ok, {list, int}}, marmot:type_info_to_type(MarmotConfig, Info)).

array_of_text_test() ->
    MarmotConfig = config(),
    BaseInfo = base_type_info(),
    Info = BaseInfo#type_info{
        module = pg_array,
        name = ~"_text",
        elem_type = BaseInfo#type_info{module = pg_raw, name = ~"text"}
    },
    ?assertEqual({ok, {list, bit_array}}, marmot:type_info_to_type(MarmotConfig, Info)).

nested_array_of_int_test() ->
    MarmotConfig = config(),
    BaseInfo = base_type_info(),
    Inner = BaseInfo#type_info{
        module = pg_array,
        name = ~"_int4",
        elem_type = BaseInfo#type_info{module = pg_int4, name = ~"int4"}
    },
    Outer = BaseInfo#type_info{
        module = pg_array,
        name = ~"__int4",
        elem_type = Inner
    },
    ?assertEqual({ok, {list, {list, int}}}, marmot:type_info_to_type(MarmotConfig, Outer)).

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
    ?assertEqual({ok, []}, marmot:resolve_parameters(config(), [])).

identifier_plain_test() ->
    ?assertEqual({ok, name}, marmot:column_name_to_identifier(~"name")).

identifier_digits_and_underscores_test() ->
    ?assertEqual({ok, a_1_b2}, marmot:column_name_to_identifier(~"a_1_b2")).

identifier_bang_suffix_test() ->
    ?assertEqual({ok, id}, marmot:column_name_to_identifier(~"id!")).

identifier_question_suffix_test() ->
    ?assertEqual({ok, value}, marmot:column_name_to_identifier(~"value?")).

identifier_leading_digit_test() ->
    ?assertEqual({error, {invalid_column, ~"1abc"}}, marmot:column_name_to_identifier(~"1abc")).

identifier_leading_underscore_test() ->
    ?assertEqual({error, {invalid_column, ~"_abc"}}, marmot:column_name_to_identifier(~"_abc")).

identifier_uppercase_test() ->
    ?assertEqual({error, {invalid_column, ~"Name"}}, marmot:column_name_to_identifier(~"Name")).

identifier_embedded_space_test() ->
    ?assertEqual(
        {error, {invalid_column, ~"Weird Name"}},
        marmot:column_name_to_identifier(~"Weird Name")
    ).

identifier_empty_test() ->
    ?assertEqual({error, {invalid_column, ~""}}, marmot:column_name_to_identifier(~"")).

identifier_non_ascii_test() ->
    ?assertEqual({error, {invalid_column, ~"oöo"}}, marmot:column_name_to_identifier(~"oöo")).

identifier_reports_original_with_suffix_test() ->
    ?assertEqual(
        {error, {invalid_column, ~"Weird Name!"}},
        marmot:column_name_to_identifier(~"Weird Name!")
    ).

nullability_override_none_test() ->
    ?assertEqual(none, marmot:nullability_override(~"name")).

nullability_override_not_nullable_test() ->
    ?assertEqual(not_nullable, marmot:nullability_override(~"name!")).

nullability_override_nullable_test() ->
    ?assertEqual(nullable, marmot:nullability_override(~"name?")).

nullability_override_empty_test() ->
    ?assertEqual(none, marmot:nullability_override(~"")).

empty_returns_test() ->
    ?assertEqual({ok, []}, marmot:resolve_returns(config(), [], sets:new())).

empty_nullability_map_test() ->
    ?assertEqual({ok, #{}}, marmot:nullability_map(config(), [])).

leading_comment_none_test() ->
    ?assertEqual([], marmot:leading_comment(~"select 1")).

leading_comment_empty_input_test() ->
    ?assertEqual([], marmot:leading_comment(~"")).

leading_comment_no_trailing_newline_test() ->
    ?assertEqual([~"a", ~"b"], marmot:leading_comment(~"-- a\n-- b")).

leading_comment_stops_at_query_test() ->
    ?assertEqual([~"a"], marmot:leading_comment(~"-- a\nselect 1 -- b\n")).

leading_comment_crlf_test() ->
    ?assertEqual([~"a"], marmot:leading_comment(~"-- a\r\nselect 1")).

leading_comment_non_ascii_test() ->
    ?assertEqual([~"café"], marmot:leading_comment(~"-- café\nselect 1")).

leading_comment_blank_line_collapses_test() ->
    ?assertEqual([~"a", ~"b"], marmot:leading_comment(~"-- a\n\n-- b\nselect 1")).

leading_comment_bare_dashes_test() ->
    ?assertEqual(
        [~"a", ~"", ~"b"], marmot:leading_comment(~"-- a\n--\n-- b\nselect 1")
    ).

leading_comment_leading_blank_lines_test() ->
    ?assertEqual([~"a"], marmot:leading_comment(~"\n\n-- a\nselect 1")).

leading_comment_strips_indentation_test() ->
    ?assertEqual([~"indented"], marmot:leading_comment(~"--   indented\nselect 1")).
