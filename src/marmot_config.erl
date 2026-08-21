-module(marmot_config).
-moduledoc """
Explicit connection configuration for marmot.

A `#config{}` names the pgo pool marmot should use, and optionally carries the
pool configuration marmot should start itself. When `connection` is `none`,
the caller has already started `Pool` and marmot only uses it.
""".

-export([new/2, from_env/0, connection_from_env/0]).

-record #config{
    pool = marmot :: pgo:pool(),
    connection = none :: none | {some, pgo:pool_config()}
}.
-export_record([config]).

-spec new(pgo:pool(), none | {some, pgo:pool_config()}) -> #config{}.
new(Pool, Connection) ->
    #config{pool = Pool, connection = Connection}.

-doc """
Build a `#config{}` from `PGO_*` environment variables, matching the defaults
marmot has always used:

- `PGO_HOST`, default `"127.0.0.1"`
- `PGO_DATABASE`, default `"marmot"`
- `PGO_USER`, default `"marmot"`
- `PGO_PASSWORD`, default `"marmot"`
- `PGO_PORT`, no default (omitted unless set)
- `PGO_POOL_SIZE`, default `1`

Always returns `#config{pool = marmot, connection = {some, _}}` — marmot owns
and starts this pool.
""".
-spec from_env() -> #config{}.
from_env() ->
    #config{pool = marmot, connection = {some, connection_from_env()}}.

-spec connection_from_env() -> pgo:pool_config().
connection_from_env() ->
    Base = #{
        host => os:getenv("PGO_HOST", "127.0.0.1"),
        database => os:getenv("PGO_DATABASE", "marmot"),
        user => os:getenv("PGO_USER", "marmot"),
        password => os:getenv("PGO_PASSWORD", "marmot"),
        pool_size => pool_size_from_env()
    },
    case os:getenv("PGO_PORT") of
        false -> Base;
        Port -> Base#{port => list_to_integer(Port)}
    end.

-spec pool_size_from_env() -> pos_integer().
pool_size_from_env() ->
    case os:getenv("PGO_POOL_SIZE") of
        false -> 1;
        Size -> list_to_integer(Size)
    end.
