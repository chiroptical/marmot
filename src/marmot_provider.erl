-module(marmot_provider).

-export([init/1, do/1, format_error/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
        {name, generate},
        {namespace, marmot},
        {module, ?MODULE},
        {bare, true},
        {deps, []},
        {opts, []},
        {short_desc, "Generate Erlang queries from PostgreSQL"},
        {desc,
            "Generate queries using the root project's marmot configuration and DATABASE_URL or PGO_* credentials."},
        {example, "rebar3 marmot generate"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, {?MODULE, term()}}.
do(State) ->
    Config = rebar_state:get(State, marmot, #{}),
    case marmot:generate(Config) of
        ok -> {ok, State};
        {error, Errors} -> {error, {?MODULE, Errors}}
    end.

-spec format_error([generator:error()]) -> iolist().
format_error(Errors) ->
    lists:join("\n", [
        io_lib:format("~ts: ~ts", [File, Module:format_error(Reason)])
     || {File, Module, Reason} <- Errors
    ]).
