-module(generator).

-import_record(marmot, [typed_query]).
-import_record(marmot_config, [config]).
-import_record(discovery, [query_module]).

-behaviour(marmot_error).

-export([generate/1, format_error/1]).

-export_type([config/0, error/0, reason/0]).

-type config() :: #{
    directories => [file:filename_all()],
    search_root => file:filename_all(),
    pool => pgo:pool(),
    connection => marmot_config:connection()
}.

-type error() :: marmot_error:error().

-type reason() ::
    {pool_start_failed, protocol:reason()}
    | {refusing_to_overwrite, string()}
    | {unreadable_output_file, string(), file:posix()}
    | {write_failed, string(), file:posix()}
    | query_plan:reason().

-spec generate(config()) -> ok | {error, [error()]}.
generate(Config) ->
    maybe
        {ok, MarmotConfig} ?= marmot_config(Config),
        {ok, Directories} ?= directories(Config),
        {ok, Modules} ?= modules(Directories),
        case Modules of
            [] ->
                logger:notice(#{what => no_query_directories, directories => Directories}),
                ok;
            _ ->
                with_pool(MarmotConfig, fun() -> generate_modules(MarmotConfig, Modules) end)
        end
    end.

-spec format_error(reason()) -> binary().
format_error(postgres_version_too_old) ->
    marmot_error:message(
        "marmot needs PostgreSQL 16 or newer. Nullability is inferred from "
        "`EXPLAIN (GENERIC_PLAN)`, which older servers do not support, and without "
        "it marmot cannot tell an always-present column from a nullable one."
    );
format_error({pool_start_failed, Reason}) ->
    marmot_error:message(
        "marmot could not start or reach its connection pool: ~p. Check the "
        "host, port and credentials it was given.",
        [Reason]
    );
format_error({refusing_to_overwrite, Output}) ->
    marmot_error:message(
        "~ts already exists and was not written by marmot — it does not start "
        "with marmot's generated-code banner. Move it aside, or rename the query "
        "directory so it generates a differently named module.",
        [Output]
    );
format_error({unreadable_output_file, Output, Reason}) ->
    marmot_error:message(
        "~ts could not be read to check whether marmot generated it: ~p. marmot "
        "will not overwrite a file it cannot identify.",
        [Output, Reason]
    );
format_error({write_failed, Output, Reason}) ->
    marmot_error:message(
        "~ts could not be written: ~p.", [Output, Reason]
    );
format_error(Reason) ->
    marmot_error:message("~p", [Reason]).

-spec marmot_config(config()) -> {ok, #config{}} | {error, [error()]}.
marmot_config(#{pool := Pool, connection := Connection}) ->
    {ok, marmot_config:new(Pool, {some, Connection})};
marmot_config(#{pool := Pool}) ->
    {ok, marmot_config:new(Pool, none)};
marmot_config(#{connection := Connection}) ->
    {ok, marmot_config:new(marmot, {some, Connection})};
marmot_config(#{}) ->
    case marmot_config:from_env() of
        {ok, MarmotConfig} -> {ok, MarmotConfig};
        {error, Reason} -> {error, [{config, marmot_config, Reason}]}
    end.

-spec directories(config()) -> {ok, [file:filename_all()]} | {error, [error()]}.
directories(#{directories := Directories}) ->
    {ok, Directories};
directories(Config) ->
    Root = maps:get(search_root, Config, "src"),
    case discovery:query_directories(Root) of
        {ok, Directories} -> {ok, Directories};
        {error, Reason} -> {error, [{Root, discovery, Reason}]}
    end.

-spec modules([file:filename_all()]) -> {ok, [#query_module{}]} | {error, [error()]}.
modules(Directories) ->
    case discovery:query_modules(Directories) of
        {ok, Modules} -> {ok, Modules};
        {error, Reason} -> {error, [{discovery_key(Reason), discovery, Reason}]}
    end.

-spec discovery_key(term()) -> file:filename_all() | config.
discovery_key({missing_directory, Directory}) -> Directory;
discovery_key({invalid_path_component, _Component, Directory}) -> Directory;
discovery_key({duplicate_module, _Module, [Directory | _]}) -> Directory;
discovery_key(_Reason) -> config.

-spec with_pool(#config{}, fun(() -> ok | {error, [error()]})) -> ok | {error, [error()]}.
with_pool(MarmotConfig = #config{pool = Pool}, Fun) ->
    Owned = owned(MarmotConfig),
    case protocol:prepare_pool(MarmotConfig) of
        ok ->
            try
                Fun()
            after
                case Owned of
                    true -> stop_pool(Pool);
                    false -> ok
                end
            end;
        {error, Reason} ->
            {error, [{config, ?MODULE, {pool_start_failed, Reason}}]}
    end.

-spec owned(#config{}) -> boolean().
owned(#config{pool = Pool, connection = {some, _}}) -> whereis(Pool) =:= undefined;
owned(#config{connection = none}) -> false.

-spec stop_pool(pgo:pool()) -> ok.
stop_pool(Pool) ->
    case whereis(Pool) of
        undefined ->
            ok;
        Pid ->
            _ = supervisor:terminate_child(pgo_sup, Pid),
            ok
    end.

-spec generate_modules(#config{}, [#query_module{}]) -> ok | {error, [error()]}.
generate_modules(MarmotConfig, Modules) ->
    maybe
        ok ?= ensure_postgres_version(MarmotConfig),
        {ok, Rendered} ?= render(MarmotConfig, Modules),
        ok ?= check_targets(Rendered),
        write(Rendered)
    end.

-spec ensure_postgres_version(#config{}) -> ok | {error, [error()]}.
ensure_postgres_version(MarmotConfig) ->
    case query_plan:ensure_postgres_version(MarmotConfig) of
        ok -> ok;
        {error, Reason} -> {error, [{config, ?MODULE, Reason}]}
    end.

-spec render(#config{}, [#query_module{}]) -> {ok, [{string(), binary()}]} | {error, [error()]}.
render(MarmotConfig, Modules) ->
    Results = [render_module(MarmotConfig, Module) || Module <- Modules],
    case lists:append([Errors || {error, Errors} <- Results]) of
        [] -> {ok, [Rendered || {ok, Rendered} <- Results]};
        Errors -> {error, Errors}
    end.

-spec render_module(#config{}, #query_module{}) ->
    {ok, {string(), binary()}} | {error, [error()]}.
render_module(MarmotConfig, QueryModule) ->
    case typed_queries(MarmotConfig, QueryModule#query_module.source_files) of
        {ok, Queries} ->
            case codegen:module(QueryModule#query_module.module, Queries) of
                {ok, Source} -> {ok, {QueryModule#query_module.output_file, Source}};
                {error, Reason} -> {error, [{QueryModule#query_module.directory, codegen, Reason}]}
            end;
        {error, _} = Error ->
            Error
    end.

-spec typed_queries(#config{}, [string()]) -> {ok, [#typed_query{}]} | {error, [error()]}.
typed_queries(MarmotConfig, Files) ->
    Results = [{File, typed_query(MarmotConfig, File)} || File <- Files],
    case [{File, marmot, Reason} || {File, {error, Reason}} <- Results] of
        [] -> {ok, [Query || {_File, {ok, Query}} <- Results]};
        Errors -> {error, Errors}
    end.

-spec typed_query(#config{}, string()) -> {ok, #typed_query{}} | {error, marmot:reason()}.
typed_query(MarmotConfig, File) ->
    maybe
        {ok, UntypedQuery} ?= marmot:from_file(File),
        marmot:infer_types(MarmotConfig, UntypedQuery)
    end.

-spec check_targets([{string(), binary()}]) -> ok | {error, [error()]}.
check_targets(Rendered) ->
    Errors = [
        {Output, ?MODULE, Reason}
     || {Output, _Source} <- Rendered,
        {error, Reason} <- [check_target(Output)]
    ],
    case Errors of
        [] -> ok;
        _ -> {error, Errors}
    end.

-spec check_target(string()) -> ok | {error, reason()}.
check_target(Output) ->
    Banner = codegen:banner(),
    Size = byte_size(Banner),
    case file:read_file(Output) of
        {error, enoent} -> ok;
        {ok, <<Banner:Size/binary, _/binary>>} -> ok;
        {ok, _} -> {error, {refusing_to_overwrite, Output}};
        {error, Reason} -> {error, {unreadable_output_file, Output, Reason}}
    end.

-spec write([{string(), binary()}]) -> ok | {error, [error()]}.
write([]) ->
    ok;
write([{Output, Source} | Rest]) ->
    case file:write_file(Output, Source) of
        ok -> write(Rest);
        {error, Reason} -> {error, [{Output, ?MODULE, {write_failed, Output, Reason}}]}
    end.
