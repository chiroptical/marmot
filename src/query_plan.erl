-module(query_plan).
-moduledoc """
Turn a Postgres `EXPLAIN (FORMAT JSON, VERBOSE, GENERIC_PLAN)` result into a
`#plan{}` tree and walk that tree to find which output columns are nullable.

This is a port of squirrel's `query_plan` and `nullables_from_plan`.
""".

-include_lib("pgo/src/pgo_internal.hrl").

-import_record(marmot, [untyped_query]).
-import_record(marmot_config, [config]).

-define(EXPLAIN_PREFIX, ~"explain (format json, verbose, generic_plan) ").
-define(MINIMUM_POSTGRES_VERSION, 160000).

-export([
    from_untyped_query/2,
    decode_plan/1,
    nullables_from_plan/1,
    ensure_postgres_version/1,
    check_version/1
]).

-export_type([join_type/0]).

-type join_type() :: full_join | left_join | right_join | inner_join | semi_join.

-record #plan{
    node_type = ~"" :: binary(),
    join_type = none :: none | {some, join_type()},
    output = [] :: [binary()],
    plans = [] :: [#plan{}]
}.
-export_record([plan]).

-doc """
Given an untyped query, run the EXPLAIN PLAN and decode it.
""".
-spec from_untyped_query(#config{}, #untyped_query{}) -> {ok, #plan{}} | {error, term()}.
from_untyped_query(Config, #untyped_query{file_content = Content}) ->
    maybe
        {ok, Json} ?= protocol:explain(Config, <<?EXPLAIN_PREFIX/binary, Content/binary>>),
        decode_plan(Json)
    else
        {error, _} = E -> E
    end.

-doc """
Given a JSON list of messages, decode the first message into a query plan.
""".
-spec decode_plan(binary()) -> {ok, #plan{}} | {error, term()}.
decode_plan(JsonBinary) ->
    try
        case json:decode(JsonBinary) of
            [Top | _] -> {ok, to_plan(maps:get(~"Plan", Top, #{}))};
            [] -> {error, no_plan};
            Other -> {error, {unexpected_plan_shape, Other}}
        end
    catch
        _:_ -> {error, invalid_json}
    end.

-spec to_plan(map()) -> #plan{}.
to_plan(Map) ->
    #plan{
        node_type = maps:get(~"Node Type", Map, ~""),
        join_type = to_join_type(maps:get(~"Join Type", Map, none)),
        output = maps:get(~"Output", Map, []),
        plans = [to_plan(P) || P <- maps:get(~"Plans", Map, [])]
    }.

-spec to_join_type(binary() | none) -> none | {some, join_type()}.
to_join_type(~"Full") -> {some, full_join};
to_join_type(~"Left") -> {some, left_join};
to_join_type(~"Right") -> {some, right_join};
to_join_type(~"Inner") -> {some, inner_join};
to_join_type(~"Semi") -> {some, semi_join};
to_join_type(_) -> none.

-doc """
Determine the nullable fields in the query from the plan.
""".
-spec nullables_from_plan(#plan{}) -> sets:set().
nullables_from_plan(#plan{} = Plan) ->
    Outputs = outputs_index_map(Plan#plan.output),
    do_nullables_from_plan(Plan, Outputs, sets:new()).

-spec do_nullables_from_plan(#plan{}, #{binary() => [non_neg_integer()]}, sets:set()) -> sets:set().
do_nullables_from_plan(#plan{join_type = JoinType, plans = Plans} = Plan, QueryOutputs, Nullables0) ->
    Nullables = sets:union(aggregate_indices(Plan, QueryOutputs), Nullables0),
    case {JoinType, Plans} of
        {{some, full_join}, _} ->
            sets:union(plan_outputs_indices(Plan, QueryOutputs), Nullables);
        {{some, right_join}, [Left, Right]} ->
            do_nullables_from_plan(
                Right,
                QueryOutputs,
                sets:union(plan_outputs_indices(Left, QueryOutputs), Nullables)
            );
        {{some, Join}, [Left, Right]} when Join =:= left_join; Join =:= semi_join ->
            do_nullables_from_plan(
                Left,
                QueryOutputs,
                sets:union(plan_outputs_indices(Right, QueryOutputs), Nullables)
            );
        {_Join, Children} ->
            lists:foldl(
                fun(P, N) -> do_nullables_from_plan(P, QueryOutputs, N) end,
                Nullables,
                Children
            )
    end.

-spec plan_outputs_indices(#plan{}, #{binary() => [non_neg_integer()]}) -> sets:set().
plan_outputs_indices(#plan{output = Output}, QueryOutputs) ->
    output_indices(Output, QueryOutputs).

-spec aggregate_indices(#plan{}, #{binary() => [non_neg_integer()]}) -> sets:set().
aggregate_indices(#plan{node_type = ~"Aggregate", output = Output}, QueryOutputs) ->
    output_indices([E || E <- Output, nullable_aggregate(E)], QueryOutputs);
aggregate_indices(#plan{}, _QueryOutputs) ->
    sets:new().

-spec nullable_aggregate(binary()) -> boolean().
nullable_aggregate(Expression) ->
    case binary:split(Expression, ~"(") of
        [Callee, _Arguments] ->
            Name = string:lowercase(Callee),
            characters:is_valid_character_set(Name) andalso
                Name =/= ~"count" andalso
                Name =/= ~"coalesce";
        _ ->
            false
    end.

-spec output_indices([binary()], #{binary() => [non_neg_integer()]}) -> sets:set().
output_indices(Names, QueryOutputs) ->
    lists:foldl(
        fun(Name, Acc) ->
            case QueryOutputs of
                #{Name := Indices} -> sets:union(sets:from_list(Indices), Acc);
                #{} -> Acc
            end
        end,
        sets:new(),
        Names
    ).

-spec outputs_index_map([binary()]) -> #{binary() => [non_neg_integer()]}.
outputs_index_map(Output) ->
    lists:foldl(
        fun({Index, Name}, Acc) ->
            maps:update_with(Name, fun(Indices) -> [Index | Indices] end, [Index], Acc)
        end,
        #{},
        lists:enumerate(0, Output)
    ).

-doc """
Ensure that the PostgreSQL version is compatible
""".
-spec ensure_postgres_version(#config{}) -> ok | {error, term()}.
ensure_postgres_version(#config{pool = Pool}) ->
    case
        pgo:query(
            "select current_setting('server_version_num') as v",
            [],
            #{decode_opts => [return_rows_as_maps], pool => Pool}
        )
    of
        #{command := select, rows := [#{~"v" := V}]} ->
            check_version(V);
        _ ->
            {error, postgres_version_too_old}
    end.

-doc """
Given a binary from `current_setting('server_version_num')` in PostgreSQL,
ensure it is greater than the minimum.
""".
-spec check_version(binary()) -> ok | {error, postgres_version_too_old}.
check_version(V) ->
    try binary_to_integer(V) of
        N when N >= ?MINIMUM_POSTGRES_VERSION -> ok;
        _ -> {error, postgres_version_too_old}
    catch
        _:_ -> {error, postgres_version_too_old}
    end.
