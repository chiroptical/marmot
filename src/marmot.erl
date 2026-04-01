-module(marmot).

-export([from_file/1]).

-record(untyped_query, {
    input_file_name :: string(),
    starting_line :: integer(),
    root_name :: file:filename_all(),
    file_content :: binary()
}).

-doc """
Given a `string()`, attempt to read the file and generate an `#untyped_query{}`.
The code assumes this is a semi-valid SQL file, i.e. it will attempt to separate
full line comments from the query.
""".
-spec from_file(FileName :: string()) ->
    {ok, UntypedQuery :: #untyped_query{}} | {error, Reason :: string()}.
from_file(FileName) ->
    maybe
        {ok, Content} ?= file:read_file(FileName),
        BaseName = filename:basename(FileName),
        RootName = filename:rootname(BaseName),
        true ?= characters:is_valid_character_set(RootName),
        {ok, #untyped_query{
            input_file_name = FileName,
            starting_line = 1,
            root_name = RootName,
            file_content = Content
        }}
    else
        {error, Reason} -> {error, Reason}
    end.
