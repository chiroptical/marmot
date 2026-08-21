-module(query_plan_tests).

-include_lib("eunit/include/eunit.hrl").

-import_record(query_plan, [plan]).

simple_seq_scan_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan","Output":["a","b"]}}]
    """,
    ?assertMatch(
        {ok, #plan{
            node_type = ~"Seq Scan", join_type = none, output = [~"a", ~"b"], plans = []
        }},
        query_plan:decode_plan(Json)
    ).

missing_node_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Output":["a"]}}]
    """,
    ?assertMatch({ok, #plan{node_type = ~""}}, query_plan:decode_plan(Json)).

missing_output_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan"}}]
    """,
    ?assertMatch(
        {ok, #plan{join_type = none, output = [], plans = []}},
        query_plan:decode_plan(Json)
    ).

missing_plans_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Seq Scan","Output":["a"]}}]
    """,
    ?assertMatch(
        {ok, #plan{join_type = none, output = [~"a"], plans = []}},
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
            join_type = {some, left_join},
            output = [~"a", ~"b"],
            plans = [
                #plan{join_type = none, output = [~"a"], plans = []},
                #plan{join_type = none, output = [~"b"], plans = []}
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
            join_type = {some, left_join},
            output = [~"a"],
            plans = [
                #plan{
                    join_type = {some, inner_join},
                    output = [~"b"],
                    plans = [
                        #plan{join_type = none, output = [~"c"], plans = []}
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
    {ok, #plan{join_type = {some, full_join}}} = query_plan:decode_plan(Json).

right_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Right","Output":["a"]}}]
    """,
    {ok, #plan{join_type = {some, right_join}}} = query_plan:decode_plan(Json).

inner_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Inner","Output":["a"]}}]
    """,
    {ok, #plan{join_type = {some, inner_join}}} = query_plan:decode_plan(Json).

semi_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Semi","Output":["a"]}}]
    """,
    {ok, #plan{join_type = {some, semi_join}}} = query_plan:decode_plan(Json).

unknown_join_type_test() ->
    Json =
        ~"""
    [{"Plan":{"Join Type":"Anti","Output":["a"]}}]
    """,
    {ok, #plan{join_type = none}} = query_plan:decode_plan(Json).

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

no_join_test() ->
    Plan = #plan{output = [~"a", ~"b"]},
    ?assertEqual([], nullable_indices(Plan)).

full_join_nullable_test() ->
    Plan = #plan{
        join_type = {some, full_join},
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([0, 1], nullable_indices(Plan)).

left_join_nullable_test() ->
    Plan = #plan{
        join_type = {some, left_join},
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([1], nullable_indices(Plan)).

right_join_nullable_test() ->
    Plan = #plan{
        join_type = {some, right_join},
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([0], nullable_indices(Plan)).

semi_join_nullable_test() ->
    Plan = #plan{
        join_type = {some, semi_join},
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([1], nullable_indices(Plan)).

inner_join_nullable_test() ->
    Plan = #plan{
        join_type = {some, inner_join},
        output = [~"a", ~"b"],
        plans = [
            #plan{output = [~"a"]},
            #plan{output = [~"b"]}
        ]
    },
    ?assertEqual([], nullable_indices(Plan)).

nested_left_join_with_full_join_test() ->
    Plan = #plan{
        join_type = {some, left_join},
        output = [~"a", ~"b", ~"c"],
        plans = [
            #plan{
                join_type = {some, full_join},
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

decoded_left_join_nullable_test() ->
    Json =
        ~"""
    [{"Plan":{"Node Type":"Hash Join","Join Type":"Left","Output":["a.name","b.value"],
    "Plans":[{"Node Type":"Seq Scan","Output":["a.name","a.id"]},
             {"Node Type":"Seq Scan","Output":["b.value","b.id"]}]}}]
    """,
    {ok, Plan} = query_plan:decode_plan(Json),
    ?assertEqual([1], nullable_indices(Plan)).

duplicate_output_names_test() ->
    Plan = #plan{
        join_type = {some, left_join},
        output = [~"b.v", ~"b.v"],
        plans = [#plan{output = [~"a.id"]}, #plan{output = [~"b.v"]}]
    },
    ?assertEqual([0, 1], nullable_indices(Plan)).

aggregate_nullable_test() ->
    Plan = #plan{
        node_type = ~"Aggregate",
        output = [~"max(a)"],
        plans = [#plan{node_type = ~"Seq Scan", output = [~"a"]}]
    },
    ?assertEqual([0], nullable_indices(Plan)).

aggregate_count_not_nullable_test() ->
    Plan = #plan{
        node_type = ~"Aggregate",
        output = [~"count(*)", ~"max(a)"],
        plans = [#plan{node_type = ~"Seq Scan", output = [~"a"]}]
    },
    ?assertEqual([1], nullable_indices(Plan)).

aggregate_coalesce_not_nullable_test() ->
    Plan = #plan{
        node_type = ~"Aggregate",
        output = [~"COALESCE(max(a), 0)"],
        plans = [#plan{node_type = ~"Seq Scan", output = [~"a"]}]
    },
    ?assertEqual([], nullable_indices(Plan)).

aggregate_group_key_not_nullable_test() ->
    Plan = #plan{
        node_type = ~"Aggregate",
        output = [~"relkind", ~"max(a)"],
        plans = [#plan{node_type = ~"Seq Scan", output = [~"relkind", ~"a"]}]
    },
    ?assertEqual([1], nullable_indices(Plan)).

non_aggregate_call_not_nullable_test() ->
    Plan = #plan{node_type = ~"Seq Scan", output = [~"lower(a)"]},
    ?assertEqual([], nullable_indices(Plan)).

aggregate_init_plan_not_nullable_test() ->
    Plan = #plan{
        node_type = ~"Aggregate",
        output = [~"(InitPlan 1).col1"],
        plans = [#plan{node_type = ~"Seq Scan", output = [~"a"]}]
    },
    ?assertEqual([], nullable_indices(Plan)).

nullable_indices(Plan) ->
    lists:sort(sets:to_list(query_plan:nullables_from_plan(Plan))).

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
