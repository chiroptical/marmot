-module(codegen_type_tests).

-include_lib("eunit/include/eunit.hrl").

render(Type) ->
    Form = {attribute, 0, type, {t, codegen_type:to_ast(Type), []}},
    iolist_to_binary(
        erl_prettypr:format(erl_syntax:form_list([Form]), [{paper, 96}, {ribbon, 90}])
    ).

render_weird(Atoms) ->
    Form =
        {attribute, 0, type, {weird, {type, 0, union, [{atom, 0, A} || A <- Atoms]}, []}},
    iolist_to_binary(
        erl_prettypr:format(erl_syntax:form_list([Form]), [{paper, 96}, {ribbon, 90}])
    ).

int_test() ->
    ?assertEqual(~"-type t() :: integer().", render(int)).

float_test() ->
    ?assertEqual(
        ~"-type t() :: float() | 'NaN' | infinity | '-infinity'.", render(float)
    ).

numeric_test() ->
    ?assertEqual(
        ~"-type t() :: number() | 'NaN' | infinity | '-infinity'.", render(numeric)
    ).

bool_test() ->
    ?assertEqual(~"-type t() :: boolean().", render(bool)).

bit_array_test() ->
    ?assertEqual(~"-type t() :: binary().", render(bit_array)).

bitstring_test() ->
    ?assertEqual(~"-type t() :: bitstring().", render(bitstring)).

uuid_test() ->
    ?assertEqual(~"-type t() :: uuid:uuid().", render(uuid)).

json_test() ->
    ?assertEqual(~"-type t() :: binary().", render(json)).

date_test() ->
    ?assertEqual(~"-type t() :: calendar:date().", render(date)).

time_of_day_test() ->
    ?assertEqual(~"-type t() :: pg_timestamp:time().", render(time_of_day)).

timestamp_test() ->
    ?assertEqual(
        ~"-type t() :: pg_timestamp:datetime() | infinity | '-infinity'.",
        render(timestamp)
    ).

option_bit_array_test() ->
    ?assertEqual(
        ~"-type t() :: none | {some, binary()}.", render({option, bit_array})
    ).

list_int_test() ->
    ?assertEqual(~"-type t() :: [integer()].", render({list, int})).

list_enum_test() ->
    ?assertEqual(
        ~"-type t() :: [mood()].",
        render({list, {enum, {1, ~"mood", [~"happy", ~"sad", ~"meh"]}}})
    ).

option_timestamp_test() ->
    ?assertEqual(
        ~"-type t() :: none | {some, pg_timestamp:datetime() | infinity | '-infinity'}.",
        render({option, timestamp})
    ).

option_list_option_bit_array_test() ->
    ?assertEqual(
        ~"-type t() :: none | {some, [none | {some, binary()}]}.",
        render({option, {list, {option, bit_array}}})
    ).

weird_enum_labels_test() ->
    ?assertEqual(
        ~"-type weird() :: 'a-b' | 'not allowed' | 'UPPER'.",
        render_weird(['a-b', 'not allowed', 'UPPER'])
    ).

enums_empty_test() ->
    ?assertEqual([], codegen_type:enums([])).

enums_option_list_enum_test() ->
    Enum = {enum, {1, ~"mood", [~"happy", ~"sad"]}},
    ?assertEqual(
        [{1, ~"mood", [~"happy", ~"sad"]}], codegen_type:enums([{option, {list, Enum}}])
    ).

enums_dedup_by_oid_test() ->
    Enum = {enum, {1, ~"mood", [~"happy", ~"sad"]}},
    ?assertEqual(
        [{1, ~"mood", [~"happy", ~"sad"]}], codegen_type:enums([Enum, Enum])
    ).

enums_distinct_oid_same_name_test() ->
    Enum1 = {enum, {1, ~"status", [~"a"]}},
    Enum2 = {enum, {2, ~"status", [~"b"]}},
    ?assertEqual(
        [{1, ~"status", [~"a"]}, {2, ~"status", [~"b"]}], codegen_type:enums([Enum1, Enum2])
    ).

compile_forms_test() ->
    Forms = [
        {attribute, 0, module, codegen_type_tests_compile_check},
        {attribute, 0, export_type, [{t1, 0}, {t2, 0}, {t3, 0}, {mood, 0}]},
        {attribute, 0, type, {t1, codegen_type:to_ast(int), []}},
        {attribute, 0, type, {t2, codegen_type:to_ast({option, timestamp}), []}},
        {attribute, 0, type,
            {t3, codegen_type:to_ast({list, {enum, {1, ~"mood", [~"happy", ~"sad"]}}}), []}},
        {attribute, 0, type, {mood, {type, 0, union, [{atom, 0, happy}, {atom, 0, sad}]}, []}}
    ],
    ?assertMatch({ok, _, _}, compile:forms(Forms, [return_errors])).
