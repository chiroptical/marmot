-module(discovery).

-export([
    query_directories/1,
    query_modules/1,
    format_error/1
]).

-record #query_module{
    module :: module(),
    directory :: string(),
    output_file :: string(),
    source_files :: [string()]
}.
-export_record([query_module]).

-spec query_directories(file:filename_all()) -> {ok, [string()]} | {error, term()}.
query_directories(Root0) ->
    Root = normalize(Root0),
    case filelib:is_dir(Root) of
        false ->
            {error, {missing_directory, Root}};
        true ->
            {ok, [
                Dir
             || Dir <- subdirectories(Root),
                not is_hidden(Dir),
                contains_sql(Dir)
            ]}
    end.

-spec query_modules([file:filename_all()]) -> {ok, [#query_module{}]} | {error, term()}.
query_modules(Directories) ->
    maybe
        {ok, PerDirectory} ?= collect([directory_modules(normalize(D)) || D <- Directories]),
        Modules = sort_by_module(lists:append(PerDirectory)),
        ok ?= check_duplicate_modules(Modules),
        {ok, Modules}
    end.

-spec format_error(term()) -> binary().
format_error({missing_directory, Directory}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "~ts is not a directory. marmot reads queries from a directory of .sql "
            "files whose name becomes the generated module's name.",
            [Directory]
        )
    );
format_error({invalid_path_component, Component, Directory}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "the path component ~ts in ~ts cannot be part of an Erlang module name; "
            "every component of a query directory's path becomes part of the "
            "generated module's name, so each must start with a lowercase letter and "
            "contain only lowercase letters, digits and underscores. Rename it.",
            [Component, Directory]
        )
    );
format_error({duplicate_module, Module, Directories}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "~ts directories all generate the module ~ts: ~ts. Erlang's module "
            "namespace is flat, so one would overwrite the other. Rename one of "
            "them.",
            [
                integer_to_list(length(Directories)),
                Module,
                lists:join(", ", Directories)
            ]
        )
    );
format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

-spec directory_modules(string()) -> {ok, [#query_module{}]} | {error, term()}.
directory_modules(Directory) ->
    case filelib:is_dir(Directory) of
        false ->
            {error, {missing_directory, Directory}};
        true ->
            case contains_sql(Directory) of
                false -> {ok, []};
                true -> walk(Directory, [filename:basename(Directory)], filename:dirname(Directory))
            end
    end.

-spec walk(string(), [string()], string()) -> {ok, [#query_module{}]} | {error, term()}.
walk(Directory, Components, OutputDirectory) ->
    maybe
        ok ?= validate_component(filename:basename(Directory), Directory),
        {ok, Nested} ?=
            collect([
                walk(Sub, Components ++ [filename:basename(Sub)], OutputDirectory)
             || Sub <- subdirectories(Directory), contains_sql(Sub)
            ]),
        {ok, module_here(Directory, Components, OutputDirectory) ++ lists:append(Nested)}
    end.

-spec module_here(string(), [string()], string()) -> [#query_module{}].
module_here(Directory, Components, OutputDirectory) ->
    case sql_files(Directory) of
        [] ->
            [];
        Files ->
            Name = lists:flatten(lists:join("_", Components)),
            [
                #query_module{
                    module = list_to_atom(Name),
                    directory = Directory,
                    output_file = filename:join(OutputDirectory, Name ++ ".erl"),
                    source_files = Files
                }
            ]
    end.

-spec validate_component(string(), string()) -> ok | {error, term()}.
validate_component(Component, Directory) ->
    case characters:is_valid_character_set(Component) of
        true -> ok;
        false -> {error, {invalid_path_component, Component, Directory}}
    end.

-spec check_duplicate_modules([#query_module{}]) -> ok | {error, term()}.
check_duplicate_modules(Modules) ->
    ByModule = lists:foldl(
        fun(#query_module{module = Module, directory = Directory}, Acc) ->
            maps:update_with(Module, fun(Ds) -> Ds ++ [Directory] end, [Directory], Acc)
        end,
        #{},
        Modules
    ),
    Duplicates = lists:sort([
        {Module, Directories}
     || {Module, Directories} <- maps:to_list(ByModule), length(Directories) > 1
    ]),
    case Duplicates of
        [] -> ok;
        [{Module, Directories} | _] -> {error, {duplicate_module, Module, Directories}}
    end.

-spec sort_by_module([#query_module{}]) -> [#query_module{}].
sort_by_module(Modules) ->
    lists:sort(
        fun(A, B) -> A#query_module.module =< B#query_module.module end,
        Modules
    ).

-spec entries(string()) -> [string()].
entries(Directory) ->
    case file:list_dir(Directory) of
        {ok, Names} -> lists:sort([filename:join(Directory, Name) || Name <- Names]);
        {error, _} -> []
    end.

-spec subdirectories(string()) -> [string()].
subdirectories(Directory) ->
    [Entry || Entry <- entries(Directory), filelib:is_dir(Entry)].

-spec sql_files(string()) -> [string()].
sql_files(Directory) ->
    [
        Entry
     || Entry <- entries(Directory),
        filelib:is_regular(Entry),
        filename:extension(Entry) =:= ".sql"
    ].

-spec contains_sql(string()) -> boolean().
contains_sql(Directory) ->
    sql_files(Directory) =/= [] orelse
        lists:any(fun contains_sql/1, subdirectories(Directory)).

-spec is_hidden(string()) -> boolean().
is_hidden(Path) ->
    case filename:basename(Path) of
        [$. | _] -> true;
        _ -> false
    end.

-spec normalize(file:filename_all()) -> string().
normalize(Path) ->
    case filename:split(to_list(Path)) of
        [] -> ".";
        Components -> filename:join(Components)
    end.

-spec to_list(file:filename_all()) -> string().
to_list(Path) when is_binary(Path) ->
    case unicode:characters_to_list(Path, utf8) of
        List when is_list(List) -> List;
        _ -> binary_to_list(Path)
    end;
to_list(Path) ->
    Path.

-spec collect([{ok, A} | {error, term()}]) -> {ok, [A]} | {error, term()}.
collect([]) ->
    {ok, []};
collect([{ok, Value} | Rest]) ->
    case collect(Rest) of
        {ok, Values} -> {ok, [Value | Values]};
        {error, _} = Error -> Error
    end;
collect([{error, _} = Error | _Rest]) ->
    Error.
