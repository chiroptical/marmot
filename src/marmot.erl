-module(marmot).
-moduledoc """
TODO
""".

-include_lib("pg_types/include/pg_types.hrl").

-define(DEFAULT_POOL, default).

-export([
    from_file/1,
    infer_types/1,
    parameters_and_returns/1,
    resolve_parameters/1,
    name_to_type/1,
    type_info_to_type/1
]).

-export_type([type/0]).

-record(#untyped_query{
    input_file_name = "" :: string(),
    starting_line = 0 :: integer(),
    % TODO: root_name should be binary
    root_name = "" :: file:filename_all(),
    file_content = <<>> :: binary()
}).
-export_record([untyped_query]).

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
    | time_of_day
    | timestamp
    | bit_array
    | int
    | float
    | numeric
    | bool
    | json
    | uuid
    | {enum, Name :: binary(), Variants :: [binary()]}
    | {list, type()}.

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

-doc """
1. Ask postgres for information about query parameters and returned rows
2. The parameters will allows us to turn OIDs into Erlang `type()`
3. Return types will give us OIDs too, but we can't know nullability
   without reading the query plan
Q: If we are unable to form a query plan, e.g. with a `do`, just assume
   the returns are nullable?
""".
-spec infer_types(#untyped_query{}) ->
    {ok, #typed_query{}}
    | {error, Reason :: string()}.
infer_types(UntypedQuery = #untyped_query{}) ->
    {ok, #typed_query{
        input_file_name = UntypedQuery#untyped_query.input_file_name,
        starting_line = UntypedQuery#untyped_query.starting_line,
        root_name = UntypedQuery#untyped_query.root_name,
        content = UntypedQuery#untyped_query.file_content,
        params = [],
        returns = []
    }}.

-doc """
1. Need a connection to make queries
2. pgo_protocol:encode_parse_message/3
3. pgo_protocol:encode_describe_message/2
4. pgo_protocol:encode_sync_message/0
5.
SocketModule can be ssl or gen_tcp, ideally we just have a pgo connection
case SocketModule:send(Socket, pgo_protocol:encode...(...)) of
    ok ->
        receive_message(SocketModule, Socket, Pool, []);
    {error, _} = SendError ->
        SendError
end.
""".
-spec parameters_and_returns(#untyped_query{}) ->
    {ok, nil}
    | {error, Reason :: string()}.
parameters_and_returns(_UntypedQuery = #untyped_query{}) ->
    {ok, nil}.

-doc """
Given a list of OIDs, resolve all of the OIDs to Erlang types. If we are unable
to resolve any of the OIDs, the entire functions returns an error tuple.
""".
-spec resolve_parameters([pos_integer()]) ->
    {ok, [type()]} | {error, term()}.
resolve_parameters(Oids) ->
    collect([resolve_oid(Oid) || Oid <- Oids]).

-spec resolve_oid(pos_integer()) ->
    {ok, type()} | {error, term()}.
resolve_oid(Oid) ->
    case pg_types:lookup_type_info(?DEFAULT_POOL, Oid) of
        unknown_oid -> {error, {unsupported_type, Oid}};
        #type_info{} = Info -> type_info_to_type(Info)
    end.

-doc """
Postgres may send us arrays, enums, or names. This function dispatches to the
appropriate handler for the recieved type information.
""".
-spec type_info_to_type(#type_info{}) ->
    {ok, type()} | {error, term()}.
type_info_to_type(#type_info{module = pg_array} = Info) ->
    resolve_array(Info);
type_info_to_type(#type_info{module = pg_enum} = Info) ->
    resolve_enum(Info);
type_info_to_type(#type_info{name = Name}) ->
    name_to_type(Name).

-doc """
For an array, we'll either have elem_type or we'll need to lookup the OID. Once
we have that, we can recursively call `type_info_to_type` until we resolve the
elements OID.
""".
-spec resolve_array(#type_info{}) ->
    {ok, type()} | {error, term()}.
resolve_array(Info) ->
    Elem =
        case Info#type_info.elem_type of
            undefined -> pg_types:lookup_type_info(?DEFAULT_POOL, Info#type_info.elem_oid);
            Other -> Other
        end,
    case Elem of
        unknown_oid ->
            {error, {unsupported_type, Info#type_info.elem_oid}};
        #type_info{} = E1 ->
            case type_info_to_type(E1) of
                {ok, T} -> {ok, {list, T}};
                Err -> Err
            end
    end.

-doc """
Convert pg_type's names to Marmot's supported types
""".
-spec name_to_type(binary()) -> {ok, type()} | {error, term()}.
name_to_type(~"int2") -> {ok, int};
name_to_type(~"int4") -> {ok, int};
name_to_type(~"int8") -> {ok, int};
name_to_type(~"oid") -> {ok, int};
name_to_type(~"float4") -> {ok, float};
name_to_type(~"float8") -> {ok, float};
name_to_type(~"numeric") -> {ok, numeric};
name_to_type(~"bool") -> {ok, bool};
name_to_type(~"text") -> {ok, bit_array};
name_to_type(~"varchar") -> {ok, bit_array};
name_to_type(~"bpchar") -> {ok, bit_array};
name_to_type(~"char") -> {ok, bit_array};
name_to_type(~"name") -> {ok, bit_array};
name_to_type(~"citext") -> {ok, bit_array};
name_to_type(~"bytea") -> {ok, bit_array};
name_to_type(~"bit") -> {ok, bit_array};
name_to_type(~"varbit") -> {ok, bit_array};
name_to_type(~"uuid") -> {ok, uuid};
name_to_type(~"json") -> {ok, json};
name_to_type(~"jsonb") -> {ok, json};
name_to_type(~"date") -> {ok, date};
name_to_type(~"time") -> {ok, time_of_day};
name_to_type(~"timestamp") -> {ok, timestamp};
name_to_type(~"timestamptz") -> {ok, timestamp};
name_to_type(Name) -> {error, {unsupported_type, Name}}.

-doc """
For enums, gather all the potential labels for the enum via pg_enum table
""".
-spec resolve_enum(#type_info{}) ->
    {ok, type()} | {error, term()}.
resolve_enum(#type_info{oid = Oid, name = Name}) ->
    case
        pgo:query(
            "select enumlabel from pg_enum where enumtypid = $1::integer order by enumsortorder",
            [Oid],
            #{decode_opts => [return_rows_as_maps]}
        )
    of
        #{command := select, rows := Rows} ->
            {ok, {enum, Name, [L || #{~"enumlabel" := L} <- Rows]}};
        _ ->
            {error, {unsupported_type, Oid}}
    end.

-spec collect(list({ok, A} | {error, E})) ->
    {ok, list(A)} | {error, E}.
collect(List) ->
    collect(List, queue:new()).

-spec collect(list({ok, A} | {error, E}), queue:queue(A)) ->
    {ok, list(A)} | {error, E}.
collect([], Q) ->
    {ok, queue:to_list(Q)};
collect([{ok, V} | Rest], Q) ->
    collect(Rest, queue:in(V, Q));
collect([{error, _} = E | _Rest], _Q) ->
    E.
