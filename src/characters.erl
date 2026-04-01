-module(characters).

-export([
    is_lower_alpha/1,
    is_digit/1,
    is_underscore/1,
    is_valid_beginning/1,
    is_valid_character_set/1
]).

-spec is_underscore(number()) -> boolean().
is_underscore($_) -> true;
is_underscore(_) -> false.

-spec is_digit(number()) -> boolean().
is_digit($0) -> true;
is_digit($1) -> true;
is_digit($2) -> true;
is_digit($3) -> true;
is_digit($4) -> true;
is_digit($5) -> true;
is_digit($6) -> true;
is_digit($7) -> true;
is_digit($8) -> true;
is_digit($9) -> true;
is_digit(_) -> false.

-spec is_lower_alpha(number()) -> boolean().
is_lower_alpha($a) -> true;
is_lower_alpha($b) -> true;
is_lower_alpha($c) -> true;
is_lower_alpha($d) -> true;
is_lower_alpha($e) -> true;
is_lower_alpha($f) -> true;
is_lower_alpha($g) -> true;
is_lower_alpha($h) -> true;
is_lower_alpha($i) -> true;
is_lower_alpha($j) -> true;
is_lower_alpha($k) -> true;
is_lower_alpha($l) -> true;
is_lower_alpha($m) -> true;
is_lower_alpha($n) -> true;
is_lower_alpha($o) -> true;
is_lower_alpha($p) -> true;
is_lower_alpha($q) -> true;
is_lower_alpha($r) -> true;
is_lower_alpha($s) -> true;
is_lower_alpha($t) -> true;
is_lower_alpha($u) -> true;
is_lower_alpha($v) -> true;
is_lower_alpha($w) -> true;
is_lower_alpha($x) -> true;
is_lower_alpha($y) -> true;
is_lower_alpha($z) -> true;
is_lower_alpha(_) -> false.

-spec is_valid_character_set(RootName :: string() | binary()) -> boolean().
is_valid_character_set(RootName) when is_binary(RootName) ->
    maybe
        true ?= is_valid_beginning(RootName),
        go_is_valid_character_set(RootName)
    else
        false -> false
    end;
is_valid_character_set(RootName) ->
    maybe
        Bin = list_to_binary(RootName),
        true ?= is_valid_beginning(Bin),
        go_is_valid_character_set(Bin)
    else
        false -> false
    end.

-spec go_is_valid_character_set(Chars :: binary()) -> boolean().

go_is_valid_character_set(~"") ->
    true;
go_is_valid_character_set(<<Char/utf8, Rest/binary>>) ->
    IsMatch = any_match(Char, [
        fun is_lower_alpha/1,
        fun is_digit/1,
        fun is_underscore/1
    ]),
    case IsMatch of
        false -> false;
        true -> go_is_valid_character_set(Rest)
    end.

-spec any_match(Bin :: integer(), Fns :: list(fun((integer()) -> boolean()))) -> boolean().
any_match(_Bin, []) ->
    false;
any_match(Bin, [H | T]) ->
    case H(Bin) of
        true -> true;
        false -> any_match(Bin, T)
    end.

-spec is_valid_beginning(binary()) -> boolean().
is_valid_beginning(~"") -> false;
is_valid_beginning(<<"_", _/binary>>) -> false;
is_valid_beginning(_) -> true.
