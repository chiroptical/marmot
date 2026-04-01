-module(characters_tests).

-include_lib("eunit/include/eunit.hrl").

is_valid_beginning_empty_test() ->
    ?assertEqual(false, characters:is_valid_beginning(~"")).

is_valid_beginning_leading_underscore_test() ->
    ?assertEqual(false, characters:is_valid_beginning(~"_abc")).

is_valid_beginning_test() ->
    ?assertEqual(true, characters:is_valid_beginning(~"abc_")).

is_valid_character_set_empty_test() ->
    ?assertEqual(false, characters:is_valid_character_set(~"")).

is_valid_character_set_leading_underscore_test() ->
    ?assertEqual(false, characters:is_valid_character_set(~"_abc")).

is_valid_character_set_umlaut_test() ->
    ?assertEqual(false, characters:is_valid_character_set(~"oöo")).

is_valid_character_set_test() ->
    ?assertEqual(true, characters:is_valid_character_set(~"abc")).
