marmot
=====

A pure Erlang implementation of [squirrel][squirrel]

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

## Plan

- [ ] Implement `infer_types`, L544 src/squirrel/internal/database/postgres.gleam
    Given `UntypedQuery`, returns `{ok, TypedQuery}` or `{error, ...}` 
    - [x] Set up `pgo` architecture for making client requests
    - [x] Write `parameters_and_returns`, see `protocol:prepare_statement/1`
    - [ ] Test `parameters_and_returns`, see `protocol:prepare_statement/1`
    - [ ] Write and test `resolve_parameters`, src/squirrel/internal/database/postgres.gleam L704
    - [ ] Write and test `query_plan`, src/squirrel/internal/database/postgres.gleam L765
    - [ ] Write and test `resolve_returns`, src/squirrel/internal/database/postgres.gleam L897

[squirrel]: https://github.com/giacomocavalieri/squirrel
