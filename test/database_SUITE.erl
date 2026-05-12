-module(database_SUITE).
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    works/1
]).

all() ->
    [works].

works(_Config) ->
    #{command := select, num_rows := 1, rows := [{Brand, Model, Year}]} = pgo:transaction(fun() ->
        pgo:query("create temporary table cars (brand text, model text, year integer)"),
        pgo:query("insert into cars (brand, model, year) values ('bmw', 'm3', 1988)"),
        pgo:query("select brand, model, year from cars")
    end),
    ?assertEqual(~"bmw", Brand),
    ?assertEqual(~"m3", Model),
    ?assertEqual(1988, Year).

init_per_suite(Config) ->
    {ok, _StartedApplications} = application:ensure_all_started(pgo),
    {ok, _Pid} = pgo:start_pool(default, #{
        pool_size => 1,
        database => "marmot",
        user => "marmot",
        password => "marmot"
    }),
    Config.

end_per_suite(_Config) ->
    application:stop(pgo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.
