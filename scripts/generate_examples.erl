-module(generate_examples).

-export([main/1]).

-spec main([string()]) -> no_return().
main(_Args) ->
    Config = #{
        directories => ["examples/sql"],
        connection => marmot_config:connection_from_env()
    },
    case marmot:generate(Config) of
        ok ->
            halt(0);
        {error, Errors} ->
            [
                io:format(standard_error, "~ts: ~ts~n", [File, generator:format_error(Reason)])
             || {File, Reason} <- Errors
            ],
            halt(1)
    end.
