-module(generate_examples).

-export([main/1]).

-spec main([string()]) -> no_return().
main(_Args) ->
    Config = #{directories => ["examples/sql"]},
    case marmot:generate(Config) of
        ok ->
            halt(0);
        {error, Errors} ->
            [
                io:format(standard_error, "~ts: ~ts~n", [File, Module:format_error(Reason)])
             || {File, Module, Reason} <- Errors
            ],
            halt(1)
    end.
