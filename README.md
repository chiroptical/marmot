marmot
=====

A pure Erlang implementation of [squirrel][squirrel]

## Status

Incomplete

## Example

Generated SQL may look like,

```erlang
-module(sql_generated).

-export([get/1]).

-spec get(SomeUuid :: uuid:uuid()) ->
    {ok, OtherUuid :: uuid:uuid(), AnotherUuid :: uuid:uuid()}.
get(SomeUuid) ->
    %% ...
    {ok, OtherUuid, AnotherUuid}.
```

Consumer,

```erlang
-module(consumer_module).

-export([some_api/0]).

-spec some_api() -> uuid:uuid().
some_api() ->
    %% Note: currently ELP will not pick up incorrect tuple size, but dialyzer will
    {ok, OtherUuid, _AnotherUuid} = sql_generated:get(uuid:get_v4()),
    OtherUuid.
```

[squirrel]: https://github.com/giacomocavalieri/squirrel
