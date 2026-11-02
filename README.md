marmot
=====

[![NixCI](https://nix-ci.com/badge/gh:chiroptical:marmot)](https://nix-ci.com/gh:chiroptical:marmot)

A pure Erlang implementation of [squirrel][squirrel]

## Status

Working, unreleased. Requires PostgreSQL 16 or newer.

## Generate from rebar3

Add Marmot to your project's `rebar.config` (requires OTP 29):

```erlang
{project_plugins, [
    {marmot, {git, "https://github.com/chiroptical/marmot.git",
        {ref, "<commit>"}}}
]}.
{marmot, #{directories => ["src/myapp_sql"]}}.
```

Apply your database schema and put one query in each `.sql` file, then run:

```sh
# marmot also accepts setting PGO_* environment variables
export DATABASE_URL='postgres://user:password@localhost:5432/myapp'
rebar3 marmot generate
rebar3 compile
```

The generated code requires `pgo` and some UUID library (I use [this
one](https://github.com/okeuday/uuid.git)). Without `directories`, it searches
`src/` recursively. You can use the `search_root` option to change that
behavior. Set `target_otp` to generate Erlang for a release without native
records.

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
