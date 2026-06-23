-module(protocol_SUITE).
-include_lib("eunit/include/eunit.hrl").
-include_lib("pgo/src/pgo_internal.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    parameterless_query/1,
    query_with_parameters/1
]).

all() ->
    [parameterless_query, query_with_parameters].

parameterless_query(_Config) ->
    {ok, [], Fields} = protocol:prepare_statement(~"select 1 as num"),
    ?assertEqual(1, length(Fields)),
    [NumField] = Fields,
    ?assertEqual(~"num", NumField#row_description_field.name),
    ?assertEqual(23, NumField#row_description_field.data_type_oid).

query_with_parameters(_Config) ->
    {ok, Params, Fields} =
        protocol:prepare_statement(~"select $1::integer as num, $2::text as label"),
    ?assertEqual([23, 25], Params),
    ?assertEqual(2, length(Fields)),
    [NumField, LabelField] = Fields,
    ?assertEqual(~"num", NumField#row_description_field.name),
    ?assertEqual(23, NumField#row_description_field.data_type_oid),
    ?assertEqual(~"label", LabelField#row_description_field.name),
    ?assertEqual(25, LabelField#row_description_field.data_type_oid).

init_per_suite(Config) ->
    ok = protocol:prepare_pool(),
    Config.

end_per_suite(_Config) ->
    application:stop(pgo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.
