-module(query_plan).
-moduledoc """
Turn a Postgres `EXPLAIN (FORMAT JSON, VERBOSE, GENERIC_PLAN)` result into a
`#plan{}` tree and walk that tree to find which output columns are nullable.

This is a port of squirrel's `query_plan` and `nullables_from_plan`.
""".

-include_lib("pgo/src/pgo_internal.hrl").

-import_record(marmot, [untyped_query]).

-define(EXPLAIN_PREFIX, ~"explain (format json, verbose, generic_plan) ").
-define(MINIMUM_POSTGRES_VERSION, 160000).

-export([
    from_untyped_query/1,
    decode_plan/1,
    nullables_from_plan/1,
    ensure_postgres_version/0,
    check_version/1
]).

-export_type([join_type/0, plan/0]).

-type join_type() :: full_join | left_join | right_join | inner_join | semi_join.

-record(#plan{
    join_type = undefined :: join_type() | undefined,
    output = [] :: [binary()],
    plans = [] :: [plan()]
}).
-export_record([plan]).

-type plan() :: #plan{}.

-doc """
TODO
""".
-spec from_untyped_query(#untyped_query{}) -> {ok, plan()} | {error, term()}.
from_untyped_query(#untyped_query{file_content = Content}) ->
    maybe
        {ok, Json} ?= protocol:explain(<<?EXPLAIN_PREFIX/binary, Content/binary>>),
        decode_plan(Json)
    else
        {error, _} = E -> E
    end.

-doc """
TODO
""".
-spec decode_plan(binary()) -> {ok, plan()} | {error, term()}.
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

-spec to_plan(map()) -> plan().
to_plan(Map) ->
    #plan{
        join_type = to_join_type(maps:get(~"Join Type", Map, undefined)),
        output = maps:get(~"Output", Map, []),
        plans = [to_plan(P) || P <- maps:get(~"Plans", Map, [])]
    }.

-spec to_join_type(binary() | undefined) -> join_type() | undefined.
to_join_type(~"Full") -> full_join;
to_join_type(~"Left") -> left_join;
to_join_type(~"Right") -> right_join;
to_join_type(~"Inner") -> inner_join;
to_join_type(~"Semi") -> semi_join;
to_join_type(_) -> undefined.

-doc """
TODO
""".
-spec nullables_from_plan(plan()) -> sets:set().
nullables_from_plan(#plan{} = Plan) ->
    Outputs = outputs_index_map(Plan#plan.output),
    do_nullables_from_plan(Plan, Outputs, sets:new()).

-spec do_nullables_from_plan(plan(), map(), sets:set()) -> sets:set().
do_nullables_from_plan(#plan{join_type = JoinType, plans = Plans} = Plan, QueryOutputs, Nullables) ->
    case {JoinType, Plans} of
        {full_join, _} ->
            sets:union(plan_outputs_indices(Plan, QueryOutputs), Nullables);
        {right_join, [Left, Right]} ->
            do_nullables_from_plan(
                Right,
                QueryOutputs,
                sets:union(plan_outputs_indices(Left, QueryOutputs), Nullables)
            );
        {Join, [Left, Right]} when Join =:= left_join; Join =:= semi_join ->
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

-spec plan_outputs_indices(plan(), map()) -> sets:set().
plan_outputs_indices(#plan{output = Output}, QueryOutputs) ->
    lists:foldl(
        fun(Name, Acc) ->
            case maps:find(Name, QueryOutputs) of
                {ok, I} -> sets:add_element(I, Acc);
                error -> Acc
            end
        end,
        sets:new(),
        Output
    ).

-spec outputs_index_map([binary()]) -> map().
outputs_index_map(Output) ->
    outputs_index_map(Output, 0, #{}).

-spec outputs_index_map([binary()], non_neg_integer(), map()) -> map().
outputs_index_map([], _I, Acc) ->
    Acc;
outputs_index_map([Name | Rest], I, Acc) ->
    outputs_index_map(Rest, I + 1, maps:put(Name, I, Acc)).

-doc """
TODO
""".
-spec ensure_postgres_version() -> ok | {error, term()}.
ensure_postgres_version() ->
    case
        pgo:query(
            "select current_setting('server_version_num') as v",
            [],
            #{decode_opts => [return_rows_as_maps]}
        )
    of
        #{command := select, rows := [#{~"v" := V}]} ->
            check_version(V);
        _ ->
            {error, postgres_version_too_old}
    end.

-doc """
TODO
""".
-spec check_version(binary()) -> ok | {error, postgres_version_too_old}.
check_version(V) ->
    try binary_to_integer(V) of
        N when N >= ?MINIMUM_POSTGRES_VERSION -> ok;
        _ -> {error, postgres_version_too_old}
    catch
        _:_ -> {error, postgres_version_too_old}
    end.
