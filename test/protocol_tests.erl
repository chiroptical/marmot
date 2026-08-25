-module(protocol_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONNECTION, #{
    host => "db.example.com",
    port => 6543,
    database => "app",
    user => "reader",
    password => "hunter2"
}).

classify(Reason) ->
    protocol:connect_error(?CONNECTION, Reason).

invalid_password_test() ->
    ?assertEqual(
        {invalid_password, "reader"},
        classify({pgo_error, #{code => ~"28P01", message => ~"password authentication failed"}})
    ).

database_does_not_exist_test() ->
    ?assertEqual(
        {database_does_not_exist, "app"},
        classify({pgo_error, #{code => ~"3D000", message => ~"database \"app\" does not exist"}})
    ).

tls_required_test() ->
    Message = ~"no pg_hba.conf entry for host \"1.2.3.4\", user \"reader\", SSL off",
    ?assertEqual(
        {tls_required, "db.example.com"},
        classify({pgo_error, #{code => ~"28000", message => Message}})
    ).

pg_hba_rejection_is_not_a_tls_problem_test() ->
    Message = ~"no pg_hba.conf entry for host \"1.2.3.4\", user \"reader\", SSL on",
    Fields = #{code => ~"28000", message => Message},
    ?assertEqual({connection_rejected, Fields}, classify({pgo_error, Fields})).

other_server_errors_are_reported_verbatim_test() ->
    Fields = #{code => ~"53300", message => ~"too many connections for role"},
    ?assertEqual({connection_rejected, Fields}, classify({pgo_error, Fields})).

connection_refused_test() ->
    ?assertEqual({connection_refused, "db.example.com", 6543}, classify(econnrefused)).

host_unreachable_test() ->
    [
        ?assertEqual({host_unreachable, "db.example.com", 6543, Posix}, classify(Posix))
     || Posix <- [ehostunreach, enetunreach, nxdomain, etimedout]
    ].

tls_not_supported_test() ->
    ?assertEqual({tls_not_supported, "db.example.com"}, classify(ssl_refused)).

tls_handshake_failed_test() ->
    Alert = {tls_alert, {unknown_ca, "received CLIENT ALERT: Fatal - Unknown CA"}},
    ?assertEqual({tls_handshake_failed, Alert}, classify(Alert)),
    Options = {options, incompatible, [cacertfile, cacerts]},
    ?assertEqual({tls_handshake_failed, Options}, classify(Options)).

unclassified_failures_keep_their_reason_test() ->
    ?assertEqual({connection_failed, econnreset}, classify(econnreset)),
    ?assertEqual({connection_failed, badarg}, classify({probe_crashed, badarg})).
