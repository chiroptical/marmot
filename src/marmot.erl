-module(marmot).

%% TODO: This needs to end up in a wrapping module
-include_lib("pgo/src/pgo_internal.hrl").

-export([
    connect/0,
    from_file/1,
    infer_types/1,
    parameters_and_returns/1
]).

%% TODO: These need to be configurable in rebar.config
connect() ->
    maybe
        {ok, _Started} ?= application:ensure_all_started(pgo),
        {ok, _Pid} ?=
            pgo:start_pool(default, #{
                pool_size => 1, host => "127.0.0.1", database => "postgres", user => "chiroptical"
            }),
        {ok, PoolRef, Conn} ?= pgo:checkout(default),
        Result = parse(Conn, "select 1"),
        ok ?= pgo:checkin(PoolRef, Conn),
        {ok, Result}
    else
        {error, Reason} ->
            logger:notice(Reason),
            {error, "Something unexpected happened"}
    end.

%% TODO: Need to send the proper series of messages and receive the response
parse(#conn{socket_module = SocketModule, socket = Socket}, Query) ->
    SocketModule:send(Socket, pgo_protocol:encode_parse_message("", Query, [])).

-record(untyped_query, {
    input_file_name :: string(),
    starting_line :: integer(),
    % TODO: root_name should be binary
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

-type type() ::
    date
    | {option, type()}
    | date
    | time_of_day
    | timestamp
    | bit_array
    | int
    | float
    | numeric
    | bool
    | string
    | json
    | uuid:uuid()
    | list(type()).

-record(field, {
    identifier :: string(),
    type :: type()
}).

-record(typed_query, {
    input_file_name :: string(),
    starting_line :: integer(),
    % TODO: root_name should be binary
    root_name :: file:filename_all(),
    content :: binary(),
    params :: list(type()),
    returns :: list(#field{})
}).

-spec infer_types(#untyped_query{}) ->
    {ok, #typed_query{}}
    | {error, Reason :: string()}.
infer_types(UntypedQuery = #untyped_query{}) ->
    % 1. Ask postgres for information about query parameters and returned rows
    % 2. The parameters will allows us to turn OIDs into Erlang `type()`
    % 3. Return types will give us OIDs too, but we can't know nullability
    %    without reading the query plan
    % Q: If we are unable to form a query plan, e.g. with a `do`, just assume
    %    the returns are nullable?
    {ok, #typed_query{
        input_file_name = UntypedQuery#untyped_query.input_file_name,
        starting_line = UntypedQuery#untyped_query.starting_line,
        root_name = UntypedQuery#untyped_query.root_name,
        content = UntypedQuery#untyped_query.file_content,
        params = [],
        returns = []
    }}.

-spec parameters_and_returns(#untyped_query{}) ->
    {ok, nil}
    | {error, Reason :: string()}.
parameters_and_returns(_UntypedQuery = #untyped_query{}) ->
    %% 1. Need a connection to make queries
    %% 2. pgo_protocol:encode_parse_message/3
    %% 3. pgo_protocol:encode_describe_message/2
    %% 4. pgo_protocol:encode_sync_message/0
    %% 5.
    %% SocketModule can be ssl or gen_tcp, ideally we just have a pgo connection
    %% case SocketModule:send(Socket, pgo_protocol:encode...(...)) of
    %%     ok ->
    %%         receive_message(SocketModule, Socket, Pool, []);
    %%     {error, _} = SendError ->
    %%         SendError
    %% end.
    {ok, nil}.
