-module(codegen_type).

-export([to_ast/1, enums/1, anno/0]).

-spec to_ast(marmot:type()) -> erl_parse:abstract_type().
to_ast(int) ->
    {type, anno(), integer, []};
to_ast(float) ->
    {type, anno(), union, [
        {type, anno(), float, []},
        {atom, anno(), 'NaN'},
        {atom, anno(), infinity},
        {atom, anno(), '-infinity'}
    ]};
to_ast(numeric) ->
    {type, anno(), union, [
        {type, anno(), number, []},
        {atom, anno(), 'NaN'},
        {atom, anno(), infinity},
        {atom, anno(), '-infinity'}
    ]};
to_ast(bool) ->
    {type, anno(), boolean, []};
to_ast(bit_array) ->
    {type, anno(), binary, []};
to_ast(bitstring) ->
    {type, anno(), bitstring, []};
to_ast(uuid) ->
    {remote_type, anno(), [{atom, anno(), uuid}, {atom, anno(), uuid}, []]};
to_ast(json) ->
    {type, anno(), binary, []};
to_ast(date) ->
    {remote_type, anno(), [{atom, anno(), calendar}, {atom, anno(), date}, []]};
to_ast(time_of_day) ->
    {remote_type, anno(), [{atom, anno(), pg_timestamp}, {atom, anno(), time}, []]};
to_ast(timestamp) ->
    {type, anno(), union, [
        {remote_type, anno(), [{atom, anno(), pg_timestamp}, {atom, anno(), datetime}, []]},
        {atom, anno(), infinity},
        {atom, anno(), '-infinity'}
    ]};
to_ast({list, T}) ->
    {type, anno(), list, [to_ast(T)]};
to_ast({option, T}) ->
    {type, anno(), union, [
        {atom, anno(), none},
        {type, anno(), tuple, [{atom, anno(), some}, to_ast(T)]}
    ]};
to_ast({enum, {_Oid, Name, _Variants}}) ->
    {user_type, anno(), enum_type_name(Name), []}.

-spec anno() -> erl_anno:anno().
anno() ->
    erl_anno:new(1).

-spec enums([marmot:type()]) -> [marmot:enum()].
enums(Types) ->
    lists:uniq(
        fun({Oid, _Name, _Variants}) -> Oid end,
        lists:flatmap(fun enums_of/1, Types)
    ).

-spec enums_of(marmot:type()) -> [marmot:enum()].
enums_of({option, T}) ->
    enums_of(T);
enums_of({list, T}) ->
    enums_of(T);
enums_of({enum, Enum}) ->
    [Enum];
enums_of(_) ->
    [].

-spec enum_type_name(binary()) -> atom().
enum_type_name(Name) ->
    binary_to_atom(Name, utf8).
