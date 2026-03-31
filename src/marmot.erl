-module(marmot).

-export([from_file/1]).

-record(untyped_query, {input_file_name :: string(), starting_line :: integer(), root_name :: file:filename_all(), file_content :: binary(), comments :: string()}).

-spec from_file(FileName :: string()) -> {ok, UntypedQuery :: #untyped_query{}} | {error, Reason :: string()}.
from_file(FileName) ->
    maybe
        {ok, Content} ?= file:read_file(FileName),
        BaseName = filename:basename(FileName),
        RootName = filename:rootname(BaseName),
        % TODO: Check RootName is valid character set
        % TODO: Pull comemnts from Content
        {ok, #untyped_query{input_file_name = FileName, starting_line = 1, root_name = RootName, file_content = Content, comments = ""}}
    else
        {error, Reason} -> {error, Reason}
    end.
