-module(marmot_test_helpers).

-include_lib("pg_types/include/pg_types.hrl").

-export([wait_for_types/1]).

wait_for_types(Pool) ->
    wait_for_types(Pool, 500).

wait_for_types(_Pool, 0) ->
    error({type_server_bootstrap_timeout, default});
wait_for_types(Pool, N) ->
    case pg_types:lookup_type_info(Pool, 23) of
        unknown_oid ->
            timer:sleep(10),
            wait_for_types(Pool, N - 1);
        #type_info{} ->
            ok
    end.
