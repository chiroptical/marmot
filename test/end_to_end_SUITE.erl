-module(end_to_end_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    generates_from_examples/1,
    generated_module_runs/1,
    left_join_decodes_option/1,
    remote_typed_columns_decode/1,
    consumer_module_compiles_and_runs/1,
    pool_decode_opts_do_not_break_decoding/1
]).

-define(MAPS_POOL, e2e_maps).

all() ->
    [
        generates_from_examples,
        generated_module_runs,
        left_join_decodes_option,
        remote_typed_columns_decode,
        consumer_module_compiles_and_runs,
        pool_decode_opts_do_not_break_decoding
    ].

init_per_suite(Config) ->
    {ok, Base} = marmot_config:from_env(),
    MarmotConfig = #config{pool = Pool} = Base#config{pool = default},
    ok = protocol:prepare_pool(MarmotConfig),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    ok = start_maps_pool(MarmotConfig),
    Examples = examples_dir(),
    apply_schema(Pool, filename:join(Examples, "schema.sql")),
    EventId = uuid:get_v4(),
    insert_fixtures(Pool, EventId),
    PrivDir = proplists:get_value(priv_dir, Config),
    Generated = generate(MarmotConfig, Examples, PrivDir),
    compile_and_load(filename:join(PrivDir, "sql.erl"), PrivDir),
    [
        {marmot_config, MarmotConfig},
        {examples, Examples},
        {event_id, EventId},
        {generated, Generated}
        | Config
    ].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_schema(Pool),
    application:stop(pgo),
    ok.

-spec examples_dir() -> string().
examples_dir() ->
    filename:join(filename:dirname(filename:dirname(?FILE)), "examples").

-spec start_maps_pool(#config{}) -> ok.
start_maps_pool(#config{connection = {some, Connection}}) ->
    protocol:prepare_pool(
        marmot_config:new(?MAPS_POOL, {some, Connection#{decode_opts => [return_rows_as_maps]}})
    ).

-spec apply_schema(pgo:pool(), string()) -> ok.
apply_schema(Pool, Path) ->
    {ok, Contents} = file:read_file(Path),
    [
        #{command := _} = pgo:query(Statement, [], #{pool => Pool})
     || Raw <- binary:split(Contents, ~";", [global]),
        Statement <- [string:trim(Raw)],
        Statement =/= ~""
    ],
    ok.

-spec drop_schema(pgo:pool()) -> ok.
drop_schema(Pool) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(Table), [], #{pool => Pool})
     || Table <- [ex_events, ex_orders, ex_users]
    ],
    pgo:query("drop type if exists ex_mood", [], #{pool => Pool}),
    ok.

-spec insert_fixtures(pgo:pool(), uuid:uuid()) -> ok.
insert_fixtures(Pool, EventId) ->
    #{command := insert} =
        pgo:query(
            "insert into ex_users (id, name, mood) values "
            "(1, 'ada', 'happy'), (2, null, 'sad'), (3, 'grace', 'happy')",
            [],
            #{pool => Pool}
        ),
    #{command := insert} =
        pgo:query(
            "insert into ex_orders (id, user_id, total) values (10, 1, 500), (11, 1, 750)",
            [],
            #{pool => Pool}
        ),
    #{command := insert} =
        pgo:query(
            "insert into ex_events (id, happened_on, happened_at, recorded_at, tags) "
            "values ($1, '2026-08-20', '13:45:00', '2026-08-20 12:00:00+00', array[1,2,3])",
            [EventId],
            #{pool => Pool}
        ),
    ok.

-spec generate(#config{}, string(), string()) -> binary().
generate(#config{pool = Pool}, Examples, PrivDir) ->
    Queries = filename:join(PrivDir, "sql"),
    ok = filelib:ensure_path(Queries),
    [
        {ok, _} = file:copy(Source, filename:join(Queries, filename:basename(Source)))
     || Source <- filelib:wildcard(filename:join([Examples, "sql", "*.sql"]))
    ],
    ok = marmot:generate(#{directories => [Queries], pool => Pool}),
    {ok, Source} = file:read_file(filename:join(PrivDir, "sql.erl")),
    Source.

-spec compile_and_load(string(), string()) -> module().
compile_and_load(Path, OutDir) ->
    {ok, Module} = compile:file(Path, [{outdir, OutDir}, debug_info, return_errors]),
    true = code:add_patha(OutDir),
    {module, Module} = code:load_file(Module),
    Module.

-spec reprint(binary()) -> binary().
reprint(Source) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Source, utf8)),
    codegen:render([
        begin
            {ok, Form} = erl_parse:parse_form(FormTokens),
            Form
        end
     || FormTokens <- form_tokens(Tokens)
    ]).

-spec form_tokens([erl_scan:token()]) -> [[erl_scan:token()]].
form_tokens([]) ->
    [];
form_tokens(Tokens) ->
    {Form, Rest} = lists:splitwith(fun(Token) -> element(1, Token) =/= dot end, Tokens),
    case Rest of
        [Dot | Tail] -> [Form ++ [Dot] | form_tokens(Tail)];
        [] -> [Form]
    end.

generates_from_examples(Config) ->
    Examples = proplists:get_value(examples, Config),
    Generated = proplists:get_value(generated, Config),
    {ok, CheckedIn} = file:read_file(filename:join(Examples, "sql.erl")),
    ?assertEqual(reprint(CheckedIn), reprint(Generated)).

generated_module_runs(_Config) ->
    {ok, 1, [Ada]} = sql:get_user(1),
    ?assertEqual({some, ~"ada"}, records:get(name, Ada)),
    ?assertEqual(happy, records:get(mood, Ada)),
    {ok, 1, [Anonymous]} = sql:get_user(2),
    ?assertEqual(none, records:get(name, Anonymous)),
    ?assertEqual({ok, 0, []}, sql:get_user(404)),
    ?assertEqual({ok, 1}, sql:insert_user(4, ~"linus", meh)),
    {ok, 1, [Linus]} = sql:get_user(4),
    ?assertEqual(meh, records:get(mood, Linus)),
    {ok, 2, Happy} = sql:list_users_by_mood(happy),
    ?assertEqual([1, 3], [records:get(id, Row) || Row <- Happy]).

left_join_decodes_option(_Config) ->
    {ok, 2, [Latest | _]} = sql:user_with_latest_order(1),
    ?assertEqual(1, records:get(user_id, Latest)),
    ?assertEqual({some, 11}, records:get(order_id, Latest)),
    ?assertEqual({some, 750}, records:get(order_total, Latest)),
    {ok, 1, [Orderless]} = sql:user_with_latest_order(2),
    ?assertEqual(none, records:get(order_id, Orderless)),
    ?assertEqual(none, records:get(order_total, Orderless)).

remote_typed_columns_decode(Config) ->
    EventId = proplists:get_value(event_id, Config),
    {ok, 1, [Event]} = sql:get_event(EventId),
    ?assertEqual(EventId, records:get(id, Event)),
    ?assertEqual({2026, 8, 20}, records:get(happened_on, Event)),
    ?assertEqual({13, 45, 0}, records:get(happened_at, Event)),
    ?assertEqual({{2026, 8, 20}, {12, 0, 0}}, records:get(recorded_at, Event)),
    ?assertEqual([1, 2, 3], records:get(tags, Event)).

consumer_module_compiles_and_runs(Config) ->
    Examples = proplists:get_value(examples, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    example_users = compile_and_load(filename:join(Examples, "example_users.erl"), PrivDir),
    ?assertEqual({ok, ~"ada"}, example_users:fetch_name(1)),
    ?assertEqual(unnamed, example_users:fetch_name(2)),
    ?assertEqual(not_found, example_users:fetch_name(404)),
    ?assertEqual({ok, happy}, example_users:fetch_mood(1)),
    ?assertEqual({ok, 750}, example_users:latest_order_total(1)),
    ?assertEqual(no_orders, example_users:latest_order_total(2)).

pool_decode_opts_do_not_break_decoding(_Config) ->
    #{rows := [#{~"id" := 1}]} =
        pgo:query("select id from ex_users where id = 1", [], #{pool => ?MAPS_POOL}),
    Result = pgo:transaction(?MAPS_POOL, fun() -> sql:get_user(1) end, #{}),
    {ok, 1, [Row]} = Result,
    ?assertEqual({some, ~"ada"}, records:get(name, Row)).
