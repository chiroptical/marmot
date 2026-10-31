-module(marmot_prv_generate).

-export([init/1, do/1, format_error/1]).

-ifdef(TEST).
-export([config/2]).
-endif.

%% These callbacks call APIs supplied by the rebar3 host, outside the library PLT.
-dialyzer({nowarn_function, [init/1, do/1]}).

%% Keep rebar types out of the library: rebar3 is the host, not a runtime dep.
-spec init(term()) -> {ok, term()}.
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

-spec do(term()) -> {ok, term()} | {error, {?MODULE, term()}}.
do(State) ->
    Root = rebar_state:dir(State),
    case config(rebar_state:get(State, marmot, #{}), Root) of
        {ok, Config} ->
            case marmot_config:connection_from_env() of
                {ok, Connection} ->
                    case marmot:generate(Config#{connection => Connection}) of
                        ok -> {ok, State};
                        {error, Errors} -> {error, {?MODULE, {generation, Errors}}}
                    end;
                {error, Reason} ->
                    {error, {?MODULE, {generation, [{config, marmot_config, Reason}]}}}
            end;
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

%% Do not print rejected values: they may contain credentials or URLs.
-spec format_error(term()) -> iolist().
format_error({invalid, Key}) ->
    io_lib:format(
        "Invalid marmot ~p configuration. Expected directories (a list of paths), search_root (a path), target_otp (a positive integer), or connect_timeout (nonnegative milliseconds or infinity).",
        [Key]
    );
format_error(duplicate_directories) ->
    "Duplicate normalized marmot directories; supply each directory once.";
format_error({generation, Errors}) ->
    lists:join("\n", [
        io_lib:format("~ts: ~ts", [File, Module:format_error(Reason)])
     || {File, Module, Reason} <- Errors
    ]).

-spec config(term(), file:filename()) -> {ok, generator:config()} | {error, term()}.
config(Value, Root) when is_map(Value) ->
    case [Key || {Key, V} <- maps:to_list(Value), not valid(Key, V)] of
        [] ->
            Config = maps:merge(#{search_root => "src", connect_timeout => 5000}, Value),
            Resolved = maps:map(
                fun
                    (directories, Paths) -> [path(P, Root) || P <- Paths];
                    (search_root, Path) -> path(Path, Root);
                    (_, V) -> V
                end,
                Config
            ),
            Ds = maps:get(directories, Resolved, []),
            case length(Ds) =:= length(lists:usort(Ds)) of
                true -> {ok, Resolved};
                false -> {error, duplicate_directories}
            end;
        [Key | _] ->
            {error, {invalid, Key}}
    end;
config(_, _) ->
    {error, {invalid, entry}}.

-spec valid(term(), term()) -> boolean().
valid(directories, Paths) -> valid_paths(Paths);
valid(search_root, Path) -> valid_path(Path);
valid(target_otp, N) -> is_integer(N) andalso N > 0;
valid(connect_timeout, infinity) -> true;
valid(connect_timeout, N) -> is_integer(N) andalso N >= 0;
valid(_, _) -> false.

-spec valid_paths(term()) -> boolean().
valid_paths([]) -> true;
valid_paths([Path | Rest]) -> valid_path(Path) andalso valid_paths(Rest);
valid_paths(_) -> false.

-spec valid_path(term()) -> boolean().
valid_path(Path) when is_binary(Path); is_list(Path) ->
    try unicode:characters_to_list(Path) of
        Chars when is_list(Chars), Chars =/= [] ->
            lists:all(fun(C) -> is_integer(C) andalso C > 0 end, Chars);
        _ ->
            false
    catch
        error:badarg -> false
    end;
valid_path(_) ->
    false.

-spec path(unicode:chardata(), file:filename()) -> file:filename_all().
path(Path, Root) ->
    Absolute = filename:absname(unicode:characters_to_list(Path), Root),
    filename:join(
        lists:reverse(
            lists:foldl(
                fun
                    (".", Acc) -> Acc;
                    ("..", ["/"]) -> ["/"];
                    ("..", [_ | Rest]) -> Rest;
                    (Part, Acc) -> [Part | Acc]
                end,
                [],
                filename:split(Absolute)
            )
        )
    ).
