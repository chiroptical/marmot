-module(marmot_config).
-moduledoc """
Explicit connection configuration for marmot.

A `#config{}` names the pgo pool marmot should use, and optionally carries the
pool configuration marmot should start itself. When `connection` is `none`,
the caller has already started `Pool` and marmot only uses it.
""".

-behaviour(marmot_error).

-export([new/2, new/3, from_env/0, connection_from_env/0, format_error/1]).

-export_type([connection/0, reason/0]).

-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_PORT, 5432).
-define(DEFAULT_POOL_SIZE, 1).
-define(DEFAULT_CONNECT_TIMEOUT_SECONDS, 5).
-define(DEFAULT_SSLMODE, "disable").

-type connection() :: #{
    host => string(),
    port => integer(),
    user => string(),
    password => string(),
    database => string(),
    pool_size => pos_integer(),
    socket_options => [gen_tcp:connect_option()],
    decode_opts => [pgo:decode_option()],
    ssl => boolean(),
    ssl_options => [ssl:tls_client_option()]
}.

-type reason() ::
    {invalid_database_url, term()}
    | {missing_credentials, [database | user | password]}
    | {invalid_integer_env, string(), string()}
    | {invalid_sslmode, string()}
    | {invalid_ssl_root_cert, string(), term()}.

-record #config{
    pool = marmot :: pgo:pool(),
    connection = none :: none | {some, connection()},
    connect_timeout = 5000 :: timeout()
}.
-export_record([config]).

-spec new(pgo:pool(), none | {some, connection()}) -> #config{}.
new(Pool, Connection) ->
    #config{pool = Pool, connection = Connection}.

-spec new(pgo:pool(), none | {some, connection()}, timeout()) -> #config{}.
new(Pool, Connection, ConnectTimeout) ->
    #config{pool = Pool, connection = Connection, connect_timeout = ConnectTimeout}.

-doc """
Build a `#config{}` from `DATABASE_URL`, or from `PGO_*` when it is unset. See
`connection_from_env/0`. `PGO_CONNECT_TIMEOUT` is in seconds, default 5.
""".
-spec from_env() -> {ok, #config{}} | {error, reason()}.
from_env() ->
    maybe
        {ok, Connection} ?= connection_from_env(),
        {ok, Seconds} ?= integer_env("PGO_CONNECT_TIMEOUT", ?DEFAULT_CONNECT_TIMEOUT_SECONDS),
        {ok, new(marmot, {some, Connection}, Seconds * 1000)}
    end.

-doc """
`DATABASE_URL` when set, otherwise `PGO_HOST` (default `"127.0.0.1"`),
`PGO_PORT` (default `5432`), `PGO_DATABASE`, `PGO_USER`, `PGO_PASSWORD` and
`PGO_SSLMODE` (`disable` | `require` | `verify-full`, default `disable`).

`PGO_POOL_SIZE` and `PGO_SSLROOTCERT` have no URL representation and are read
either way.
""".
-spec connection_from_env() -> {ok, connection()} | {error, reason()}.
connection_from_env() ->
    maybe
        {ok, Base, SslMode} ?= base_from_env(),
        {ok, PoolSize} ?= integer_env("PGO_POOL_SIZE", ?DEFAULT_POOL_SIZE),
        {ok, Ssl} ?= ssl_from_sslmode(SslMode),
        {ok, maps:merge(Base#{pool_size => PoolSize}, Ssl)}
    end.

-spec format_error(reason()) -> binary().
format_error({invalid_database_url, Reason}) ->
    marmot_error:message(
        "DATABASE_URL could not be read: ~p. marmot expects "
        "`postgres://user:password@host:port/database`, optionally with "
        "`?sslmode=disable|require|verify-full`.",
        [Reason]
    );
format_error({missing_credentials, Missing}) ->
    marmot_error:message(
        "marmot was given no ~ts to connect with. Set DATABASE_URL, or set "
        "PGO_DATABASE, PGO_USER and PGO_PASSWORD, or pass `connection => "
        "#{database => ..., user => ..., password => ...}` to `marmot:generate/1`.",
        [conjoin([atom_to_list(Key) || Key <- Missing])]
    );
format_error({invalid_integer_env, Variable, Value}) ->
    marmot_error:message(
        "~ts is set to ~ts, which is not a number.", [Variable, Value]
    );
format_error({invalid_sslmode, SslMode}) ->
    marmot_error:message(
        "~ts is not an sslmode marmot supports. Use `disable`, `require` or "
        "`verify-full` — libpq's `prefer` and `allow` need a plaintext retry "
        "that pgo does not implement.",
        [SslMode]
    );
format_error({invalid_ssl_root_cert, Path, no_certificates}) ->
    marmot_error:message(
        "~ts holds no PEM certificates. PGO_SSLROOTCERT wants the CA bundle "
        "that signed the server's certificate.",
        [Path]
    );
format_error({invalid_ssl_root_cert, Path, Reason}) ->
    marmot_error:message(
        "PGO_SSLROOTCERT points at ~ts, which could not be read: ~p.", [Path, Reason]
    );
format_error(Reason) ->
    marmot_error:message("~p", [Reason]).

-spec conjoin([string()]) -> string().
conjoin([Only]) -> Only;
conjoin([First, Last]) -> First ++ " or " ++ Last;
conjoin([First | Rest]) -> First ++ ", " ++ conjoin(Rest).

-spec base_from_env() -> {ok, connection(), string()} | {error, reason()}.
base_from_env() ->
    case os:getenv("DATABASE_URL") of
        false -> base_from_variables();
        Url -> base_from_url(Url)
    end.

-spec base_from_variables() -> {ok, connection(), string()} | {error, reason()}.
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
                {ok,
                    Base#{
                        host => os:getenv("PGO_HOST", ?DEFAULT_HOST),
                        port => Port
                    },
                    os:getenv("PGO_SSLMODE", ?DEFAULT_SSLMODE)}
            end;
        Missing ->
            {error, {missing_credentials, Missing}}
    end.

-spec base_from_url(string()) -> {ok, connection(), string()} | {error, reason()}.
base_from_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme} = Parts when Scheme =:= "postgres"; Scheme =:= "postgresql" ->
            base_from_url_parts(Parts);
        #{} ->
            {error, {invalid_database_url, unsupported_scheme}};
        {error, Reason, _Term} ->
            {error, {invalid_database_url, Reason}}
    end.

-spec base_from_url_parts(uri_string:uri_map()) -> {ok, connection(), string()} | {error, reason()}.
base_from_url_parts(Parts) ->
    maybe
        {ok, Host} ?= url_host(Parts),
        {ok, Database} ?= url_database(Parts),
        {ok, User, Password} ?= url_userinfo(Parts),
        {ok,
            #{
                host => Host,
                port => maps:get(port, Parts, ?DEFAULT_PORT),
                database => Database,
                user => User,
                password => Password
            },
            url_sslmode(Parts)}
    end.

-spec url_host(uri_string:uri_map()) -> {ok, string()} | {error, reason()}.
url_host(#{host := Host}) when Host =/= "" -> {ok, Host};
url_host(#{}) -> {error, {invalid_database_url, missing_host}}.

-spec url_database(uri_string:uri_map()) -> {ok, string()} | {error, reason()}.
url_database(#{path := [$/ | Path]}) when Path =/= "" -> percent_decode(Path);
url_database(#{}) -> {error, {invalid_database_url, missing_database}}.

-spec url_userinfo(uri_string:uri_map()) -> {ok, string(), string()} | {error, reason()}.
url_userinfo(#{userinfo := UserInfo}) ->
    case string:split(UserInfo, ":") of
        [User, Password] when User =/= "" ->
            maybe
                {ok, DecodedUser} ?= percent_decode(User),
                {ok, DecodedPassword} ?= percent_decode(Password),
                {ok, DecodedUser, DecodedPassword}
            end;
        _ ->
            {error, {invalid_database_url, missing_password}}
    end;
url_userinfo(#{}) ->
    {error, {invalid_database_url, missing_user}}.

-spec url_sslmode(uri_string:uri_map()) -> string().
url_sslmode(#{query := Query}) ->
    case lists:keyfind("sslmode", 1, uri_string:dissect_query(Query)) of
        {"sslmode", SslMode} when is_list(SslMode) -> SslMode;
        _ -> ?DEFAULT_SSLMODE
    end;
url_sslmode(#{}) ->
    ?DEFAULT_SSLMODE.

-spec percent_decode(string()) -> {ok, string()} | {error, reason()}.
percent_decode(Encoded) ->
    case uri_string:percent_decode(Encoded) of
        Decoded when is_list(Decoded) -> {ok, Decoded};
        {error, Reason, _Term} -> {error, {invalid_database_url, Reason}}
    end.

-spec ssl_from_sslmode(string()) -> {ok, connection()} | {error, reason()}.
ssl_from_sslmode("disable") ->
    {ok, #{ssl => false}};
ssl_from_sslmode("require") ->
    {ok, #{ssl => true, ssl_options => [{verify, verify_none}]}};
ssl_from_sslmode("verify-full") ->
    case os:getenv("PGO_SSLROOTCERT") of
        false ->
            {ok, #{ssl => true, ssl_options => []}};
        Path ->
            maybe
                {ok, Certificates} ?= cacerts(Path),
                {ok, #{ssl => true, ssl_options => [{cacerts, Certificates}]}}
            end
    end;
ssl_from_sslmode(SslMode) ->
    {error, {invalid_sslmode, SslMode}}.

-spec cacerts(string()) -> {ok, [public_key:der_encoded()]} | {error, reason()}.
cacerts(Path) ->
    case file:read_file(Path) of
        {ok, Pem} ->
            case [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)] of
                [] -> {error, {invalid_ssl_root_cert, Path, no_certificates}};
                Certificates -> {ok, Certificates}
            end;
        {error, Reason} ->
            {error, {invalid_ssl_root_cert, Path, Reason}}
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
