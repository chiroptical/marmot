-module(discovery_SUITE).

-include_lib("eunit/include/eunit.hrl").

-import_record(discovery, [query_module]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    flat_directory/1,
    nested_directory/1,
    subdirectory_without_sql_ignored/1,
    invalid_root_component/1,
    invalid_nested_component/1,
    nested_and_sibling_collide/1,
    same_basename_directories_collide/1,
    missing_directory/1,
    results_are_sorted/1,
    query_directories_finds_roots/1,
    query_directories_without_queries/1,
    query_directories_missing_root/1,
    invalid_query_file_name/1
]).

all() ->
    [
        flat_directory,
        nested_directory,
        subdirectory_without_sql_ignored,
        invalid_root_component,
        invalid_nested_component,
        nested_and_sibling_collide,
        same_basename_directories_collide,
        missing_directory,
        results_are_sorted,
        query_directories_finds_roots,
        query_directories_without_queries,
        query_directories_missing_root,
        invalid_query_file_name
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    Base = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(TestCase)),
    ok = filelib:ensure_path(Base),
    [{base, Base} | Config].

end_per_testcase(_TestCase, Config) ->
    Config.

-spec tree(list(), [string()]) -> string().
tree(Config, Paths) ->
    Base = proplists:get_value(base, Config),
    [
        begin
            Full = filename:join(Base, Path),
            ok = filelib:ensure_dir(Full),
            ok = file:write_file(Full, ~"select 1\n")
        end
     || Path <- Paths
    ],
    Base.

-spec directory(string(), string()) -> string().
directory(Base, Relative) ->
    filename:join(Base, Relative).

flat_directory(Config) ->
    Base = tree(Config, ["src/myapp_sql/insert_user.sql", "src/myapp_sql/get_user.sql"]),
    {ok, [Module]} = discovery:query_modules([directory(Base, "src/myapp_sql")]),
    ?assertEqual(myapp_sql, Module#query_module.module),
    ?assertEqual(directory(Base, "src/myapp_sql"), Module#query_module.directory),
    ?assertEqual(directory(Base, "src/myapp_sql.erl"), Module#query_module.output_file),
    ?assertEqual(
        [
            directory(Base, "src/myapp_sql/get_user.sql"),
            directory(Base, "src/myapp_sql/insert_user.sql")
        ],
        Module#query_module.source_files
    ).

nested_directory(Config) ->
    Base = tree(Config, ["src/sql_myapp/whatever.sql", "src/sql_myapp/admin/purge.sql"]),
    {ok, [Root, Nested]} = discovery:query_modules([directory(Base, "src/sql_myapp")]),
    ?assertEqual(sql_myapp, Root#query_module.module),
    ?assertEqual(directory(Base, "src/sql_myapp.erl"), Root#query_module.output_file),
    ?assertEqual(sql_myapp_admin, Nested#query_module.module),
    ?assertEqual(directory(Base, "src/sql_myapp/admin"), Nested#query_module.directory),
    ?assertEqual(directory(Base, "src/sql_myapp_admin.erl"), Nested#query_module.output_file),
    ?assertEqual(
        [directory(Base, "src/sql_myapp/admin/purge.sql")], Nested#query_module.source_files
    ).

subdirectory_without_sql_ignored(Config) ->
    Base = tree(Config, [
        "src/sql_myapp/whatever.sql",
        "src/sql_myapp/notes/README.md",
        "src/sql_myapp/Notes/README.md"
    ]),
    {ok, [Module]} = discovery:query_modules([directory(Base, "src/sql_myapp")]),
    ?assertEqual(sql_myapp, Module#query_module.module).

invalid_root_component(Config) ->
    Base = tree(Config, ["src/SQL-myapp/whatever.sql"]),
    ?assertEqual(
        {error, {invalid_path_component, "SQL-myapp", directory(Base, "src/SQL-myapp")}},
        discovery:query_modules([directory(Base, "src/SQL-myapp")])
    ).

invalid_nested_component(Config) ->
    Base = tree(Config, ["src/sql_myapp/whatever.sql", "src/sql_myapp/Admin/purge.sql"]),
    ?assertEqual(
        {error, {invalid_path_component, "Admin", directory(Base, "src/sql_myapp/Admin")}},
        discovery:query_modules([directory(Base, "src/sql_myapp")])
    ).

nested_and_sibling_collide(Config) ->
    Base = tree(Config, ["src/sql_myapp/admin/purge.sql", "src/sql_myapp_admin/purge.sql"]),
    ?assertEqual(
        {error,
            {duplicate_module, sql_myapp_admin, [
                directory(Base, "src/sql_myapp/admin"),
                directory(Base, "src/sql_myapp_admin")
            ]}},
        discovery:query_modules([
            directory(Base, "src/sql_myapp"),
            directory(Base, "src/sql_myapp_admin")
        ])
    ).

same_basename_directories_collide(Config) ->
    Base = tree(Config, ["a/sql/get_user.sql", "b/sql/get_order.sql"]),
    ?assertEqual(
        {error, {duplicate_module, sql, [directory(Base, "a/sql"), directory(Base, "b/sql")]}},
        discovery:query_modules([directory(Base, "a/sql"), directory(Base, "b/sql")])
    ).

missing_directory(Config) ->
    Base = proplists:get_value(base, Config),
    ?assertEqual(
        {error, {missing_directory, directory(Base, "src/nope")}},
        discovery:query_modules([directory(Base, "src/nope")])
    ).

results_are_sorted(Config) ->
    Base = tree(Config, ["src/b_sql/z.sql", "src/b_sql/a.sql", "src/a_sql/q.sql"]),
    {ok, Modules} = discovery:query_modules([
        directory(Base, "src/b_sql"), directory(Base, "src/a_sql")
    ]),
    ?assertEqual([a_sql, b_sql], [M#query_module.module || M <- Modules]),
    [_, BSql] = Modules,
    ?assertEqual(
        [directory(Base, "src/b_sql/a.sql"), directory(Base, "src/b_sql/z.sql")],
        BSql#query_module.source_files
    ).

query_directories_finds_roots(Config) ->
    Base = tree(Config, [
        "src/a_sql/x.sql",
        "src/b_sql/nested/y.sql",
        "src/plain/thing.erl",
        "src/.hidden/h.sql",
        "src/loose.sql"
    ]),
    ?assertEqual(
        {ok, [directory(Base, "src/a_sql"), directory(Base, "src/b_sql")]},
        discovery:query_directories(directory(Base, "src"))
    ).

query_directories_without_queries(Config) ->
    Base = tree(Config, ["src/plain/thing.erl"]),
    ?assertEqual({ok, []}, discovery:query_directories(directory(Base, "src"))).

query_directories_missing_root(Config) ->
    Base = proplists:get_value(base, Config),
    ?assertEqual(
        {error, {missing_directory, directory(Base, "src")}},
        discovery:query_directories(directory(Base, "src"))
    ).

invalid_query_file_name(Config) ->
    Base = tree(Config, ["src/myapp_sql/Get-User.sql"]),
    ?assertEqual(
        {error, {invalid_query_file_name, "Get-User"}},
        marmot:from_file(directory(Base, "src/myapp_sql/Get-User.sql"))
    ).
