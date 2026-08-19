-module(marmot).
-moduledoc """
TODO
""".

-include_lib("pg_types/include/pg_types.hrl").
-include_lib("pgo/src/pgo_internal.hrl").

-import_record(marmot_config, [config]).

-export([
    from_file/1,
    leading_comment/1,
    infer_types/2,
    resolve_parameters/2,
    resolve_returns/3,
    column_name_to_identifier/1,
    nullability_override/1,
    nullability_map/2,
    name_to_type/1,
    type_info_to_type/2,
    explain_error_kind/1,
    format_error/1
]).

-export_type([type/0, enum/0]).

-record(#untyped_query{
    input_file_name = "" :: string(),
    starting_line = 0 :: integer(),
    % TODO: root_name should be binary
    root_name = "" :: file:filename_all(),
    file_content = <<>> :: binary(),
    doc = [] :: [binary()]
}).
-export_record([untyped_query]).

-type type() ::
    date
    | {option, type()}
    | time_of_day
    | timestamp
    | bit_array
    | bitstring
    | int
    | float
    | numeric
    | bool
    | json
    | uuid
    | {enum, enum()}
    | {list, type()}.

-type enum() :: {Oid :: pos_integer(), Name :: binary(), Variants :: [binary()]}.

-record #field{
    identifier :: atom(),
    type :: type(),
    assumed_not_null = false :: boolean()
}.
-export_record([field]).

-record #typed_query{
    input_file_name :: string(),
    starting_line :: integer(),
    % TODO: root_name should be binary
    root_name :: file:filename_all(),
    content :: binary(),
    params :: list(type()),
    returns :: list(#field{}),
    doc = [] :: [binary()]
}.
-export_record([typed_query]).

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
            file_content = Content,
            doc = leading_comment(Content)
        }}
    else
        {error, Reason} -> {error, Reason}
    end.

-spec leading_comment(binary()) -> [binary()].
leading_comment(Content) ->
    case iolist_to_binary(string:trim(Content, leading)) of
        <<"--", Rest/binary>> ->
            case binary:split(Rest, ~"\n") of
                [Line, Tail] -> [trim(Line) | leading_comment(Tail)];
                [Line] -> [trim(Line)]
            end;
        _ ->
            []
    end.

-spec trim(binary()) -> binary().
trim(Line) ->
    iolist_to_binary(string:trim(Line)).

-doc """
1. Ask postgres for information about query parameters and returned rows
2. The parameters will allows us to turn OIDs into Erlang `type()`
3. Return types will give us OIDs too, but we can't know nullability
   without reading the query plan
If Postgres cannot form a query plan for the statement, nullability falls
back to `pg_attribute.attnotnull` plus the `!`/`?` column-name suffixes
rather than assuming every returned column is nullable.
""".
-spec infer_types(#config{}, #untyped_query{}) ->
    {ok, #typed_query{}} | {error, term()}.
infer_types(Config, UntypedQuery = #untyped_query{file_content = Content}) ->
    maybe
        {ok, ParamOids, Fields} ?= protocol:prepare_statement(Config, Content),
        {ok, Params} ?= resolve_parameters(Config, ParamOids),
        {ok, Nullables} ?= nullables(Config, UntypedQuery),
        {ok, Returns} ?= resolve_returns(Config, Fields, Nullables),
        {ok, #typed_query{
            input_file_name = UntypedQuery#untyped_query.input_file_name,
            starting_line = UntypedQuery#untyped_query.starting_line,
            root_name = UntypedQuery#untyped_query.root_name,
            content = Content,
            params = Params,
            returns = Returns,
            doc = UntypedQuery#untyped_query.doc
        }}
    else
        {error, _} = E -> E
    end.

-spec nullables(#config{}, #untyped_query{}) ->
    {ok, sets:set(non_neg_integer())} | {error, term()}.
nullables(Config, UntypedQuery) ->
    case query_plan:from_untyped_query(Config, UntypedQuery) of
        {ok, Plan} ->
            {ok, query_plan:nullables_from_plan(Plan)};
        {error, {explain_failed, Fields}} ->
            case explain_error_kind(Fields) of
                {non_dml, Keyword} ->
                    {error, {non_dml_statement, Keyword}};
                unplannable ->
                    logger:notice(#{
                        what => explain_failed,
                        file => UntypedQuery#untyped_query.input_file_name,
                        fields => Fields
                    }),
                    {ok, sets:new()}
            end;
        {error, _} = E ->
            E
    end.

-spec explain_error_kind(map()) -> {non_dml, binary()} | unplannable.
explain_error_kind(#{code := ~"42601", message := Message}) ->
    {non_dml, non_dml_keyword(Message)};
explain_error_kind(#{}) ->
    unplannable.

-spec non_dml_keyword(binary()) -> binary().
non_dml_keyword(Message) ->
    case binary:split(Message, ~"\"", [global]) of
        [_, Keyword | _] -> Keyword;
        _ -> ~"statement"
    end.

-doc """
Given a list of OIDs, resolve all of the OIDs to Erlang types. If we are unable
to resolve any of the OIDs, the entire functions returns an error tuple.
""".
-spec resolve_parameters(#config{}, [pos_integer()]) ->
    {ok, [type()]} | {error, term()}.
resolve_parameters(Config, Oids) ->
    collect([resolve_oid(Config, Oid) || Oid <- Oids]).

-doc """

""".
-spec resolve_returns(#config{}, [#row_description_field{}], sets:set(non_neg_integer())) ->
    {ok, [#field{}]} | {error, term()}.
resolve_returns(Config, Fields, Nullables) ->
    maybe
        {ok, NotNull} ?= nullability_map(Config, Fields),
        collect([
            resolve_return(Config, Field, Index, Nullables, NotNull)
         || {Index, Field} <- lists:enumerate(0, Fields)
        ])
    else
        {error, _} = E -> E
    end.

-dialyzer({nowarn_function, resolve_return/5}).
-spec resolve_return(
    #config{}, #row_description_field{}, non_neg_integer(), sets:set(non_neg_integer()), map()
) ->
    {ok, #field{}} | {error, term()}.
resolve_return(Config, Field, Index, Nullables, NotNull) ->
    Name = iolist_to_binary(Field#row_description_field.name),
    maybe
        {ok, Identifier} ?= column_name_to_identifier(Name),
        {ok, Type} ?= resolve_oid(Config, Field#row_description_field.data_type_oid),
        Nullable = is_nullable(Name, Index, Field, Nullables, NotNull),
        Wrapped =
            case Nullable of
                true -> {option, Type};
                false -> Type
            end,
        AssumedNotNull =
            not Nullable andalso
                Field#row_description_field.table_oid =:= 0 andalso
                nullability_override(Name) =:= none,
        {ok, #field{identifier = Identifier, type = Wrapped, assumed_not_null = AssumedNotNull}}
    else
        {error, _} = E -> E
    end.

-spec is_nullable(
    binary(), non_neg_integer(), #row_description_field{}, sets:set(non_neg_integer()), map()
) ->
    boolean().
is_nullable(Name, Index, Field, Nullables, NotNull) ->
    case nullability_override(Name) of
        not_nullable ->
            false;
        nullable ->
            true;
        none ->
            case sets:is_element(Index, Nullables) of
                true ->
                    true;
                false ->
                    Key = {
                        Field#row_description_field.table_oid,
                        Field#row_description_field.attr_number
                    },
                    case NotNull of
                        #{Key := AttNotNull} ->
                            AttNotNull =/= true;
                        #{} ->
                            false
                    end
            end
    end.

-doc """
""".
-spec column_name_to_identifier(iodata()) -> {ok, atom()} | {error, term()}.
column_name_to_identifier(Name0) ->
    Name = iolist_to_binary(Name0),
    case Name of
        ~"?column?" ->
            {error, {unaliased_expression_column, Name}};
        _ ->
            Stripped = strip_nullability_suffix(Name),
            case characters:is_valid_character_set(Stripped) of
                true -> {ok, binary_to_atom(Stripped, utf8)};
                false -> {error, {invalid_column, Name}}
            end
    end.

-doc """
""".
-spec nullability_override(iodata()) -> not_nullable | nullable | none.
nullability_override(Name0) ->
    case iolist_to_binary(Name0) of
        ~"" -> none;
        Name -> suffix_override(binary:last(Name))
    end.

-spec suffix_override(byte()) -> not_nullable | nullable | none.
suffix_override($!) -> not_nullable;
suffix_override($?) -> nullable;
suffix_override(_) -> none.

-spec strip_nullability_suffix(binary()) -> binary().
strip_nullability_suffix(~"") ->
    ~"";
strip_nullability_suffix(Name) ->
    Size = byte_size(Name) - 1,
    case Name of
        <<Rest:Size/binary, $!>> -> Rest;
        <<Rest:Size/binary, $?>> -> Rest;
        _ -> Name
    end.

-define(NULLABILITY_SQL,
    ~"""
select a.attnotnull
from unnest($1::int4[], $2::int4[]) with ordinality as t(rel, num, ord)
left join pg_attribute a on a.attrelid = t.rel::oid and a.attnum = t.num::int2
order by t.ord
"""
).

-doc """
""".
-spec nullability_map(#config{}, [#row_description_field{}]) ->
    {ok, #{{integer(), integer()} => boolean() | null}} | {error, term()}.
nullability_map(Config, Fields) ->
    Pairs = lists:uniq([
        {TableOid, AttrNumber}
     || #row_description_field{table_oid = TableOid, attr_number = AttrNumber} <- Fields,
        TableOid =/= 0
    ]),
    case Pairs of
        [] -> {ok, #{}};
        _ -> query_nullability(Config, Pairs)
    end.

-spec query_nullability(#config{}, [{integer(), integer()}]) ->
    {ok, #{{integer(), integer()} => boolean() | null}} | {error, term()}.
query_nullability(#config{pool = Pool}, Pairs) ->
    Relations = [Relation || {Relation, _} <- Pairs],
    Numbers = [Number || {_, Number} <- Pairs],
    Options = #{decode_opts => [return_rows_as_maps], pool => Pool},
    case pgo:query(?NULLABILITY_SQL, [Relations, Numbers], Options) of
        #{command := select, rows := Rows} when length(Rows) =:= length(Pairs) ->
            NotNullByPair =
                #{
                    Pair => NotNull
                 || {Pair, #{~"attnotnull" := NotNull}} <- lists:zip(Pairs, Rows)
                },
            {ok, NotNullByPair};
        _ ->
            {error, {nullability_lookup_failed, Pairs}}
    end.

-spec resolve_oid(#config{}, pos_integer()) ->
    {ok, type()} | {error, term()}.
resolve_oid(Config = #config{pool = Pool}, Oid) ->
    case pg_types:lookup_type_info(Pool, Oid) of
        unknown_oid -> {error, {unsupported_type, Oid}};
        #type_info{} = Info -> type_info_to_type(Config, Info)
    end.

-doc """
Postgres may send us arrays, enums, or names. This function dispatches to the
appropriate handler for the recieved type information.
""".
-spec type_info_to_type(#config{}, #type_info{}) ->
    {ok, type()} | {error, term()}.
type_info_to_type(Config, #type_info{module = pg_array} = Info) ->
    resolve_array(Config, Info);
type_info_to_type(Config, #type_info{module = pg_enum} = Info) ->
    resolve_enum(Config, Info);
type_info_to_type(_Config, #type_info{name = Name}) ->
    name_to_type(Name).

-doc """
For an array, we'll either have elem_type or we'll need to lookup the OID. Once
we have that, we can recursively call `type_info_to_type` until we resolve the
elements OID.
""".
-spec resolve_array(#config{}, #type_info{}) ->
    {ok, type()} | {error, term()}.
resolve_array(Config = #config{pool = Pool}, Info) ->
    Elem =
        case Info#type_info.elem_type of
            undefined -> pg_types:lookup_type_info(Pool, Info#type_info.elem_oid);
            Other -> Other
        end,
    case Elem of
        unknown_oid ->
            {error, {unsupported_type, Info#type_info.elem_oid}};
        #type_info{} = E1 ->
            case type_info_to_type(Config, E1) of
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
name_to_type(~"bit") -> {ok, bitstring};
name_to_type(~"varbit") -> {ok, bitstring};
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
-spec resolve_enum(#config{}, #type_info{}) ->
    {ok, type()} | {error, term()}.
resolve_enum(#config{pool = Pool}, #type_info{oid = Oid, name = Name}) ->
    case
        pgo:query(
            "select enumlabel from pg_enum where enumtypid = $1::integer order by enumsortorder",
            [Oid],
            #{decode_opts => [return_rows_as_maps], pool => Pool}
        )
    of
        #{command := select, rows := Rows} ->
            {ok, {enum, {Oid, Name, [L || #{~"enumlabel" := L} <- Rows]}}};
        _ ->
            {error, {unsupported_type, Oid}}
    end.

-spec format_error(term()) -> binary().
format_error({non_dml_statement, Keyword}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "this statement starts with ~ts, which Postgres's query planner "
            "rejects with a 42601 syntax error under EXPLAIN even though it is "
            "valid SQL; marmot only supports statements EXPLAIN can plan. Run "
            "schema-changing or session statements like this through migrations "
            "or `psql` instead. Note that `SET` on a pooled connection leaks "
            "session state to whichever request borrows the connection next.",
            [Keyword]
        )
    );
format_error({unaliased_expression_column, Name}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "an output column named ~ts arrived from an unaliased expression; "
            "Postgres does not give marmot a usable field name for it. Add an "
            "alias in the query, e.g. `select u.id + 1 as total`.",
            [Name]
        )
    );
format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

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
