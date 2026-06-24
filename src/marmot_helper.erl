-module(marmot_helper).

-export([collect/1]).

-doc """
TODO
""".
-spec collect(list({ok, A} | {error, E})) ->
    {ok, list(A)} | {error, E}.
collect(List) ->
    collect(List, queue:new()).

-spec collect(list({ok, A} | {error, E}), queue:queue(A)) ->
    {ok, list(A)} | {error, E}.
collect([], Q) ->
    {ok, queue:to_list(Q)};
collect([{ok, V} | Rest], Q) ->
    collect(Rest, queue:in(V, Q));
collect([{error, _} = E | _Rest], _Q) ->
    E.
