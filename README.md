marmot
=====

[![NixCI](https://nix-ci.com/badge/gh:chiroptical:marmot)](https://nix-ci.com/gh:chiroptical:marmot)

A pure Erlang implementation of [squirrel][squirrel]

## Status

Working, unreleased. Requires PostgreSQL 16 or newer.

## Generate from rebar3

Marmot runs on OTP 29 and PostgreSQL 16 or newer. Add it as a developer
plugin in your project's `rebar.config`, pinning a Git commit:

```erlang
{project_plugins, [
    {marmot, {git, "https://github.com/chiroptical/marmot.git",
        {ref, "<pinned-marmot-commit>"}}}
]}.
{marmot, #{
    directories => ["src/myapp_sql"],
    target_otp => 29,
    connect_timeout => 5000
}}.
```

Declare the runtime dependencies of the generated code separately: `pgo`, and
`uuid` when queries use UUID types. Until Hex publication, use the pinned Git
sources from Marmot's [`rebar.config`](rebar.config) for those dependencies.
`pg_types` (including timestamp types) arrives through pgo.

Apply your database schema, put one query in each `.sql` file, then run:

```sh
export DATABASE_URL='postgres://user:password@localhost:5432/myapp'
rebar3 marmot generate
rebar3 compile
```

Alternatively set `PGO_DATABASE`, `PGO_USER`, and `PGO_PASSWORD`, with optional
`PGO_HOST` (default `127.0.0.1`) and `PGO_PORT` (default `5432`). `DATABASE_URL`
takes precedence. TLS uses URL `sslmode` or `PGO_SSLMODE` (`disable`, `require`,
`verify-full`), with `PGO_SSLROOTCERT` for a CA bundle. Standard `PG*` variables
are not read. Credentials belong in the environment; `connection` and `pool`
are library-only options and are rejected in plugin configuration.

The optional `marmot` entry is a map accepting only these four keys:

- `directories`: explicit query directories, taking precedence over `search_root`.
  Duplicate normalized paths are rejected.
- `search_root`: recursively scan for queries, default `"src"`. An existing empty
  root succeeds with a notice; a missing root fails.
- `target_otp`: positive integer, default the running OTP release. Pin this for
  reproducible output. A target below 29 emits classic records in a `.hrl` when
  needed; it does not lower the plugin's OTP 29 runtime requirement.
- `connect_timeout`: nonnegative milliseconds or `infinity`, default `5000`.
  This plugin setting is independent of the library's `PGO_CONNECT_TIMEOUT`.

Paths resolve from the rebar project root; absolute paths are preserved. For an
umbrella, use the root configuration with explicit paths such as
`apps/myapp/src/myapp_sql`. The selected rebar profile's effective configuration
is used; per-application settings are not merged. Generation runs before consumer
compilation and has no automatic hooks or CLI overrides. Commit the generated
`.erl` and any `.hrl` files. Prefix query directories with your application name
because their names determine generated module names.

## Regeneration in CI

On supported Linux systems, `nix build .#checks.x86_64-linux.plugin` (or
`aarch64-linux`) creates a temporary standalone consumer, installs the plugin
from a pinned local Git source, and supplies all dependencies from Nix inputs.
The build itself needs no public network access. It provisions PostgreSQL using
the existing test hook, reuses `examples/`, generates before compilation, then
compiles and executes the handwritten consumer. It also checks provider errors,
profiles, umbrella paths, and classic header output.

In the same check, output pinned to OTP 29 is formatted with the flake's pinned
erlfmt and compared by file inventory and bytes against committed
`examples/sql.erl`. Stale, missing, or extra artifacts in the declared output
scope fail with filesystem differences. Existing end-to-end tests cover classic
`.erl`/`.hrl` and record-less layouts; compiling classic output on OTP 29 does
not establish OTP 28 runtime support. Database-backed flake checks are excluded
on Darwin.

Downstream projects can adopt this regeneration/format/comparison pattern, or
regenerate and format in a clean checkout and fail when
`git status --porcelain --untracked-files=all -- <generated-output-paths>`
produces output. Include untracked files in that check. Regeneration does not
detect or delete orphaned output files it never touches. There is no Marmot
check command or check API.

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
