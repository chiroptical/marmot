-module(marmot_error_tests).

-include_lib("eunit/include/eunit.hrl").

authored_reasons(marmot) ->
    [
        {invalid_query_file_name, "Get-Order"},
        {invalid_column, ~"Weird Name"},
        {unaliased_expression_column, ~"?column?"},
        {non_dml_statement, ~"set"},
        {unsupported_type, ~"money"},
        {unsupported_type, 790},
        {nullability_lookup_failed, [{16384, 1}]},
        {prepare_failed, #{
            code => ~"42P01",
            message => ~"relation \"no_such_table\" does not exist",
            position => ~"16"
        }},
        {explain_failed, #{code => ~"0A000", message => ~"feature not supported"}}
    ];
authored_reasons(codegen) ->
    [
        {duplicate_output_columns, "get_user", [id]},
        {enum_conflict, ~"status", [16384, 16385]},
        {name_collision, get_user, 1}
    ];
authored_reasons(discovery) ->
    [
        {missing_directory, "src/sql"},
        {invalid_path_component, "Admin", "src/sql/Admin"},
        {duplicate_module, sql_admin, ["a/sql/admin", "b/sql/admin"]}
    ];
authored_reasons(generator) ->
    [
        missing_connection,
        postgres_version_too_old,
        {pool_start_failed, ~"Unable to start connection pool"},
        {refusing_to_overwrite, "src/sql.erl"},
        {unreadable_output_file, "src/sql.erl", eacces},
        {write_failed, "src/sql.erl", enospc}
    ].

-define(MODULES, [marmot, codegen, discovery, generator]).

every_authored_reason_has_a_message_test_() ->
    [
        {
            lists:flatten(io_lib:format("~p ~p", [Module, Reason])),
            fun() ->
                {module, Module} = code:ensure_loaded(Module),
                Message = Module:format_error(Reason),
                ?assert(is_binary(Message)),
                ?assertNotEqual(marmot_error:message("~p", [Reason]), Message)
            end
        }
     || Module <- ?MODULES, Reason <- authored_reasons(Module)
    ].

unknown_reason_falls_back_to_p_test_() ->
    Reason = {not_a_real_error, 1, 2},
    [
        {
            atom_to_list(Module),
            fun() ->
                {module, Module} = code:ensure_loaded(Module),
                ?assertEqual(
                    marmot_error:message("~p", [Reason]),
                    Module:format_error(Reason)
                )
            end
        }
     || Module <- ?MODULES
    ].

message_returns_a_binary_test() ->
    ?assertEqual(~"a 1", marmot_error:message("a ~p", [1])).

message_survives_invalid_unicode_test() ->
    ?assertEqual(~"<error message was not valid unicode>", marmot_error:message([16#DFFF])).
