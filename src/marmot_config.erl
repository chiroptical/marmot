-module(marmot_config).
-moduledoc """
Explicit connection configuration for marmot.

A `#config{}` names the pgo pool marmot should use, and optionally carries the
pool configuration marmot should start itself. When `connection` is `none`,
the caller has already started `Pool` and marmot only uses it.
""".

-behaviour(marmot_error).

-export([new/2, from_env/0, connection_from_env/0, format_error/1]).

-export_type([connection/0, reason/0]).

-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_PORT, 5432).
-define(DEFAULT_POOL_SIZE, 1).

-type connection() :: #{
    host => string(),
    port => integer(),
    user => string(),
    password => string(),
    database => string(),
    pool_size => pos_integer(),
    socket_options => [gen_tcp:connect_option()],
    decode_opts => [pgo:decode_option()]
}.

-type reason() ::
    {missing_credentials, [database | user | password]}
    | {invalid_integer_env, string(), string()}.

-record #config{
    pool = marmot :: pgo:pool(),
    connection = none :: none | {some, connection()}
}.
-export_record([config]).

-spec new(pgo:pool(), none | {some, connection()}) -> #config{}.
new(Pool, Connection) ->
    #config{pool = Pool, connection = Connection}.

-doc """
Build a `#config{}` from `PGO_*` environment variables. See
`connection_from_env/0`.
""".
-spec from_env() -> {ok, #config{}} | {error, reason()}.
from_env() ->
    maybe
        {ok, Connection} ?= connection_from_env(),
        {ok, new(marmot, {some, Connection})}
    end.

-doc """
`PGO_HOST` (default `"127.0.0.1"`), `PGO_PORT` (default `5432`),
`PGO_DATABASE`, `PGO_USER`, `PGO_PASSWORD` and `PGO_POOL_SIZE` (default `1`).
The three credentials have no default.
""".
-spec connection_from_env() -> {ok, connection()} | {error, reason()}.
connection_from_env() ->
    maybe
        {ok, Base} ?= base_from_variables(),
        {ok, PoolSize} ?= integer_env("PGO_POOL_SIZE", ?DEFAULT_POOL_SIZE),
        {ok, Base#{pool_size => PoolSize}}
    end.

-spec format_error(reason()) -> binary().
format_error({missing_credentials, Missing}) ->
    marmot_error:message(
        "marmot was given no ~ts to connect with. Set PGO_DATABASE, PGO_USER "
        "and PGO_PASSWORD, or pass `connection => #{database => ..., user => "
        "..., password => ...}` to `marmot:generate/1`.",
        [conjoin([atom_to_list(Key) || Key <- Missing])]
    );
format_error({invalid_integer_env, Variable, Value}) ->
    marmot_error:message(
        "~ts is set to ~ts, which is not a number.", [Variable, Value]
    );
format_error(Reason) ->
    marmot_error:message("~p", [Reason]).

-spec conjoin([string()]) -> string().
conjoin([Only]) -> Only;
conjoin([First, Last]) -> First ++ " or " ++ Last;
conjoin([First | Rest]) -> First ++ ", " ++ conjoin(Rest).

-spec base_from_variables() -> {ok, connection()} | {error, reason()}.
base_from_variables() ->
    Required = [
        {database, os:getenv("PGO_DATABASE")},
        {user, os:getenv("PGO_USER")},
        {password, os:getenv("PGO_PASSWORD")}
    ],
    case [Key || {Key, false} <- Required] of
        [] ->
            maybe
                {ok, Port} ?= integer_env("PGO_PORT", ?DEFAULT_PORT),
                Base = maps:from_list(Required),
                {ok, Base#{
                    host => os:getenv("PGO_HOST", ?DEFAULT_HOST),
                    port => Port
                }}
            end;
        Missing ->
            {error, {missing_credentials, Missing}}
    end.

-spec integer_env(string(), integer()) -> {ok, integer()} | {error, reason()}.
integer_env(Variable, Default) ->
    case os:getenv(Variable) of
        false ->
            {ok, Default};
        Value ->
            try
                {ok, list_to_integer(Value)}
            catch
                error:badarg -> {error, {invalid_integer_env, Variable, Value}}
            end
    end.
