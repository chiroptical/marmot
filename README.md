marmot
=====

[![NixCI](https://nix-ci.com/badge/gh:chiroptical:marmot)](https://nix-ci.com/gh:chiroptical:marmot)

A pure Erlang implementation of [squirrel][squirrel]

## Status

Working, unreleased. Requires PostgreSQL 16 or newer.

## Example

`src/sql/get_user.sql`,

```sql
-- Get a user by id.
select id, name, mood from ex_users where id = $1
```

generates `src/sql.erl`,

```erlang
-record #get_user_row{id :: integer(),
                      name :: none | {some, binary()},
                      mood :: ex_mood()}.

-spec get_user(Arg1 :: integer()) ->
    {ok, non_neg_integer(), [#get_user_row{}]}
    | {error, term()}.
```

Consumer,

```erlang
-module(consumer_module).

-export([some_api/1]).

-spec some_api(integer()) -> none | {some, binary()}.
some_api(Id) ->
    {ok, 1, [Row]} = sql:get_user(Id),
    records:get(name, Row).
```

See [`examples/`](examples/) for the whole generated module and a consumer of it.

[squirrel]: https://github.com/giacomocavalieri/squirrel
