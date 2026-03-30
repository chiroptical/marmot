-module(marmot).

-export([from_file/1]).

-spec from_file(FileName :: string()) -> {ok, Contents :: binary()} | {error, Reason :: string()}.
from_file(FileName) ->
    maybe
        {ok, Contents} = file:read_file(FileName),
        {ok, Contents}
    else
        {error, Reason} -> {error, Reason}
    end.
