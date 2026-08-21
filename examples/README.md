examples
========

A worked example of what marmot generates, checked in so it can be read without
running anything — and so `make check` can type-check it.

```
schema.sql          the fixture schema the queries are typed against
sql/*.sql           the queries: one file, one generated function
sql.erl             generated from sql/ by marmot — do not edit
example_users.erl   a hand-written consumer of sql.erl
```

`sql/` becomes module `sql` because a query directory's name becomes the
generated module's name. Erlang's module namespace is flat and global, so a real
project should prefix the directory with its application name — `myapp_sql/`,
giving `myapp_sql.erl` — rather than claiming a name as short as `sql`. The
example is short because it is an example.

Regenerate
----------

```
psql "postgres://marmot:marmot@127.0.0.1:5432/marmot" -f examples/schema.sql
make examples
```

`make examples` reads `PGO_HOST`, `PGO_DATABASE`, `PGO_USER`, `PGO_PASSWORD` and
`PGO_PORT`, defaulting to the local `marmot` database marmot's own tests use. It
rewrites `sql.erl` in place; regenerating without a schema change produces
byte-identical output.

Apply `schema.sql` first every time. `make test` creates these tables and drops
them again when it finishes, like every other suite's fixtures, so a regeneration
after a test run fails with `relation "ex_users" does not exist` until you do.

What the queries are for
------------------------

Each file exists to make the emitter produce something specific:

| File | Shows |
|---|---|
| `get_user.sql` | a leading `--` comment becoming `-doc`; a nullable column becoming `none \| {some, binary()}`; an enum column decoding to an atom |
| `insert_user.sql` | a statement with no result columns, so the function returns `{ok, Count}`; an enum passed as a parameter |
| `list_users_by_mood.sql` | an enum parameter and a multi-row result |
| `user_with_latest_order.sql` | a `left join`, whose right-hand columns are nullable even though the underlying columns are `not null`. Both are aliased, because two columns named `id` would be a duplicate record field and marmot refuses to generate one |
| `get_event.sql` | the types marmot borrows from its dependencies: `uuid:uuid()`, `calendar:date()`, `pg_timestamp:time()`, `pg_timestamp:datetime()` |

That last row is the reason this directory is under dialyzer. `compile:forms/2`
does not resolve remote types, so a module referencing `nonexistent_mod:nope()`
compiles clean; dialyzer is what proves those four names still exist and mean
what the generated `-spec`s claim.

`example_users.erl` is the other half of the proof: it names those types in its
own `-spec`s and pattern-matches the generated records, so dialyzer checks the
generated code against a caller rather than in isolation.

Testing
-------

`test/end_to_end_SUITE.erl` regenerates from `sql/` into its `priv_dir` and
asserts the result is byte-identical to the checked-in `sql.erl`, then compiles,
loads and calls it against live Postgres. A stale `sql.erl` fails the suite.
