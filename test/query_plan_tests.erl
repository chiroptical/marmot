-module(query_plan_tests).

-include_lib("eunit/include/eunit.hrl").

-import_record(query_plan, [plan]).

%% =========================================================================
%% decode_plan/1
%% =========================================================================

simple_seq_scan_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan","Output":["a","b"]}}]
    """,
    ?assertMatch(
        {ok, #plan{join_type = undefined, output = [~"a", ~"b"], plans = []}},
        query_plan:decode_plan(Json)
    ).

missing_output_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan"}}]
    """,
    ?assertMatch(
        {ok, #plan{join_type = undefined, output = [], plans = []}},
        query_plan:decode_plan(Json)
    ).

missing_plans_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan","Output":["a"]}}]
    """,
    ?assertMatch(
        {ok, #plan{join_type = undefined, output = [~"a"], plans = []}},
        query_plan:decode_plan(Json)
    ).

left_join_two_children_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Hash Join","Join Type":"Left","Output":["a","b"],
    "Plans":[{"Node Type":"Seq Scan","Output":["a"]},
             {"Node Type":"Seq Scan","Output":["b"]}]}}]
    """,
    ?assertMatch(
        {ok, #plan{
            join_type = left_join,
            output = [~"a", ~"b"],
            plans = [
                #plan{join_type = undefined, output = [~"a"], plans = []},
                #plan{join_type = undefined, output = [~"b"], plans = []}
            ]
        }},
        query_plan:decode_plan(Json)
    ).

deeply_nested_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Left","Output":["a"],
    "Plans":[{"Join Type":"Inner","Output":["b"],
    "Plans":[{"Node Type":"Seq Scan","Output":["c"]}]}]}}]
    """,
    ?assertMatch(
        {ok, #plan{
            join_type = left_join,
            output = [~"a"],
            plans = [
                #plan{
                    join_type = inner_join,
                    output = [~"b"],
                    plans = [
                        #plan{join_type = undefined, output = [~"c"], plans = []}
                    ]
                }
            ]
        }},
        query_plan:decode_plan(Json)
    ).

full_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Full","Output":["a"]}}]
    """,
    {ok, #plan{join_type = full_join}} = query_plan:decode_plan(Json).

right_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Right","Output":["a"]}}]
    """,
    {ok, #plan{join_type = right_join}} = query_plan:decode_plan(Json).

inner_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Inner","Output":["a"]}}]
    """,
    {ok, #plan{join_type = inner_join}} = query_plan:decode_plan(Json).

semi_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Semi","Output":["a"]}}]
    """,
    {ok, #plan{join_type = semi_join}} = query_plan:decode_plan(Json).

unknown_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Anti","Output":["a"]}}]
    """,
    {ok, #plan{join_type = undefined}} = query_plan:decode_plan(Json).

invalid_json_test() ->
    ?assertEqual({error, invalid_json}, query_plan:decode_plan(~"not json")).

empty_array_test() ->
    ?assertEqual({error, no_plan}, query_plan:decode_plan(~"[]")).

multiple_top_level_test() ->
    Json =
        ~"""
    [{"Plan":{"Output":["a"]}},{"Plan":{"Output":["b"]}}]
    """,
    {ok, #plan{output = Output}} = query_plan:decode_plan(Json),
    ?assertEqual([~"a"], Output).

%% =========================================================================
%% nullables_from_plan/1
%% =========================================================================

no_join_test() ->
    Plan = #plan{output = [~"a", ~"b"]},
    ?assertEqual([], nullable_indices(Plan)).

full_join_nullable_test() ->
    Plan = #plan{
        join_type = full_join,
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([0, 1], nullable_indices(Plan)).

left_join_nullable_test() ->
    Plan = #plan{
        join_type = left_join,
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([1], nullable_indices(Plan)).

right_join_nullable_test() ->
    Plan = #plan{
        join_type = right_join,
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([0], nullable_indices(Plan)).

semi_join_nullable_test() ->
    Plan = #plan{
        join_type = semi_join,
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([1], nullable_indices(Plan)).

inner_join_nullable_test() ->
    Plan = #plan{
        join_type = inner_join,
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([], nullable_indices(Plan)).

nested_left_join_with_full_join_test() ->
    Plan = #plan{
        join_type = left_join,
        output = [~"a", ~"b", ~"c"],
        plans = [
            #plan{
                join_type = full_join,
                output = [~"a", ~"b"],
                plans = [
                    #plan{output = [~"a"]},
                    #plan{output = [~"b"]}
                ]
            },
            #plan{output = [~"c"]}
        ]
    },
    ?assertEqual([0, 1, 2], nullable_indices(Plan)).

%% Helper: return sorted list of nullable indices for a plan
nullable_indices(Plan) ->
    lists:sort(sets:to_list(query_plan:nullables_from_plan(Plan))).

%% =========================================================================
%% check_version/1
%% =========================================================================

check_version_ok_test() ->
    ?assertEqual(ok, query_plan:check_version(~"170000")).

check_version_exact_minimum_test() ->
    ?assertEqual(ok, query_plan:check_version(~"160000")).

check_version_too_old_test() ->
    ?assertEqual(
        {error, postgres_version_too_old},
        query_plan:check_version(~"159999")
    ).

check_version_non_integer_test() ->
    ?assertEqual(
        {error, postgres_version_too_old},
        query_plan:check_version(~"not_a_number")
    ).

check_version_empty_test() ->
    ?assertEqual(
        {error, postgres_version_too_old},
        query_plan:check_version(~"")
    ).
