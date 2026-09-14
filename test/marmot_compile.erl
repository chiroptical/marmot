-module(marmot_compile).

-export([forms/1]).

-spec forms([term()]) -> {ok, module(), binary()} | {error, term()}.
forms(Forms) ->
    Source = codegen:render(Forms),
    File = filename:join(tmp_dir(), "marmot_" ++ unique() ++ ".erl"),
    ok = file:write_file(File, Source),
    try
        case compile:file(File, [binary, return_errors, return_warnings, debug_info]) of
            {ok, Module, Binary, []} -> {ok, Module, Binary};
            {ok, _, _, Warnings} -> {error, {warnings, Source, Warnings}};
            Error -> Error
        end
    after
        file:delete(File)
    end.

-spec tmp_dir() -> string().
tmp_dir() ->
    os:getenv("TMPDIR", "/tmp").

-spec unique() -> string().
unique() ->
    integer_to_list(erlang:unique_integer([positive])).
