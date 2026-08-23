-module(marmot_error).

-export([message/2, message/1]).

-export_type([error/0, reason/0]).

-type error() :: {file:filename_all() | config, module(), reason()}.

-type reason() ::
    marmot:reason()
    | codegen:reason()
    | discovery:reason()
    | generator:reason().

-callback format_error(reason()) -> binary().

-spec message(io:format(), [term()]) -> binary().
message(Format, Args) ->
    message(io_lib:format(Format, Args)).

-spec message(unicode:chardata()) -> binary().
message(Chardata) ->
    case unicode:characters_to_binary(Chardata) of
        Binary when is_binary(Binary) -> Binary;
        _ -> ~"<error message was not valid unicode>"
    end.
