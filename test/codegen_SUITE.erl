-module(codegen_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(marmot, [untyped_query, typed_query, field]).
-import_record(marmot_config, [config]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    not_null_column_decodes_plain/1,
    nullable_column_decodes_option/1,
    enum_column_decodes_atom/1,
    tricky_label_enum_decodes_atom/1,
    enum_round_trip/1,
    array_column_decodes_list/1,
    wrongly_guessed_not_null_column_errors/1,
    utf8_sql_round_trips_exact_bytes/1
]).

all() ->
    [
        not_null_column_decodes_plain,
        nullable_column_decodes_option,
        enum_column_decodes_atom,
        tricky_label_enum_decodes_atom,
        enum_round_trip,
        array_column_decodes_list,
        wrongly_guessed_not_null_column_errors,
        utf8_sql_round_trips_exact_bytes
    ].

init_per_suite(Config) ->
    Base = marmot_config:from_env(),
    MarmotConfig = #config{pool = Pool} = Base#config{pool = default},
    ok = protocol:prepare_pool(MarmotConfig),
    drop_tables(Pool),
    [
        pgo:query("drop type if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [cg_mood, cg_weird]
    ],
    #{command := create} =
        pgo:query("create type cg_mood as enum ('happy', 'sad', 'meh')", [], #{pool => Pool}),
    #{command := create} =
        pgo:query("create type cg_weird as enum ('a-b', 'not allowed', 'UPPER')", [], #{
            pool => Pool
        }),
    #{command := create} =
        pgo:query(
            "create table cg_items (id int not null, name text, mood cg_mood not null, "
            "tags int[] not null)",
            [],
            #{pool => Pool}
        ),
    #{command := create} =
        pgo:query(
            "create table cg_weird_items (id int not null, w cg_weird not null)",
            [],
            #{pool => Pool}
        ),
    #{command := insert} =
        pgo:query(
            "insert into cg_items (id, name, mood, tags) values "
            "(1, 'one', 'happy', array[1,2,3])",
            [],
            #{pool => Pool}
        ),
    #{command := insert} =
        pgo:query(
            "insert into cg_items (id, name, mood, tags) values "
            "(2, null, 'sad', array[]::int[])",
            [],
            #{pool => Pool}
        ),
    ok = query_plan:ensure_postgres_version(MarmotConfig),
    {module, marmot} = code:ensure_loaded(marmot),
    {module, codegen} = code:ensure_loaded(codegen),
    [{marmot_config, MarmotConfig} | Config].

end_per_suite(Config) ->
    #config{pool = Pool} = proplists:get_value(marmot_config, Config),
    drop_tables(Pool),
    application:stop(pgo),
    ok.

drop_tables(Pool) ->
    [
        pgo:query("drop table if exists " ++ atom_to_list(N), [], #{pool => Pool})
     || N <- [cg_items, cg_weird_items]
    ],
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

-spec generate_and_load(#config{}, atom(), string(), binary()) -> module().
generate_and_load(MarmotConfig, Module, RootName, Statement) ->
    {ok, TypedQuery} = marmot:infer_types(MarmotConfig, #untyped_query{
        root_name = RootName,
        file_content = Statement
    }),
    {ok, Forms} = codegen:forms(Module, [TypedQuery]),
    {ok, _, Binary} = compile:forms(Forms, [return_errors]),
    {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
    Module.

not_null_column_decodes_plain(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_not_null_sql, "cg_not_null", ~"select id from cg_items where id = $1"
    ),
    {ok, 1, [Row]} = Mod:cg_not_null(1),
    ?assertEqual(1, records:get(id, Row)).

nullable_column_decodes_option(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_nullable_sql, "cg_nullable", ~"select name from cg_items where id = $1"
    ),
    {ok, 1, [Row1]} = Mod:cg_nullable(1),
    ?assertEqual({some, ~"one"}, records:get(name, Row1)),
    {ok, 1, [Row2]} = Mod:cg_nullable(2),
    ?assertEqual(none, records:get(name, Row2)).

enum_column_decodes_atom(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_enum_sql, "cg_enum", ~"select mood from cg_items where id = $1"
    ),
    {ok, 1, [Row]} = Mod:cg_enum(1),
    ?assertEqual(happy, records:get(mood, Row)).

tricky_label_enum_decodes_atom(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_weird_sql, "cg_weird_q", ~"select $1::cg_weird as w"
    ),
    {ok, 1, [Row1]} = Mod:cg_weird_q('a-b'),
    ?assertEqual('a-b', records:get(w, Row1)),
    {ok, 1, [Row2]} = Mod:cg_weird_q('not allowed'),
    ?assertEqual('not allowed', records:get(w, Row2)),
    {ok, 1, [Row3]} = Mod:cg_weird_q('UPPER'),
    ?assertEqual('UPPER', records:get(w, Row3)).

enum_round_trip(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    #config{pool = Pool} = MarmotConfig,
    ReadMod = generate_and_load(
        MarmotConfig,
        cg_weird_read_sql,
        "cg_weird_read",
        ~"select w from cg_weird_items where id = $1"
    ),
    WriteMod = generate_and_load(
        MarmotConfig,
        cg_weird_write_sql,
        "cg_weird_write",
        ~"insert into cg_weird_items (id, w) values ($1, $2::cg_weird)"
    ),
    Variants = [{101, 'a-b'}, {102, 'not allowed'}, {103, 'UPPER'}],
    [
        begin
            {ok, 1} = WriteMod:cg_weird_write(Id, Label),
            {ok, 1, [Row]} = ReadMod:cg_weird_read(Id),
            ?assertEqual(Label, records:get(w, Row)),
            #{rows := [{RawLabel}]} =
                pgo:query(
                    "select w::text from cg_weird_items where id = $1", [Id], #{pool => Pool}
                ),
            ?assertEqual(atom_to_binary(Label, utf8), RawLabel)
        end
     || {Id, Label} <- Variants
    ].

array_column_decodes_list(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_array_sql, "cg_array", ~"select tags from cg_items where id = $1"
    ),
    {ok, 1, [Row]} = Mod:cg_array(1),
    ?assertEqual([1, 2, 3], records:get(tags, Row)).

wrongly_guessed_not_null_column_errors(Config) ->
    MarmotConfig = proplists:get_value(marmot_config, Config),
    Mod = generate_and_load(
        MarmotConfig, cg_agg_sql, "cg_agg", ~"select nullif(1, 1) as m"
    ),
    ?assertEqual({error, {unexpected_null, m}}, Mod:cg_agg()).

utf8_sql_round_trips_exact_bytes(_Config) ->
    Content = <<"-- caf", 195, 169, " ok\nselect 1 as one">>,
    Query = #typed_query{
        input_file_name = "cg_utf8.sql",
        starting_line = 1,
        root_name = "cg_utf8",
        content = Content,
        params = [],
        returns = [#field{identifier = one, type = int}],
        doc = []
    },
    Module = cg_utf8_sql,
    {ok, Forms} = codegen:forms(Module, [Query]),
    {ok, _, Binary} = compile:forms(Forms, [return_errors]),
    {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary),
    ?assertEqual(Content, Module:cg_utf8_sql()).
