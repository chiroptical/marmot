-module(example_users).

-import_record(sql, [
    get_user_row,
    list_users_by_mood_row,
    user_with_latest_order_row,
    get_event_row
]).

-export([
    fetch_name/1,
    fetch_mood/1,
    add/3,
    ids_in_mood/1,
    latest_order_total/1,
    event_recorded_at/1
]).

-spec fetch_name(Id :: integer()) ->
    {ok, binary()} | unnamed | not_found | {error, term()}.
fetch_name(Id) ->
    case sql:get_user(Id) of
        {ok, 1, [#get_user_row{name = {some, Name}}]} -> {ok, Name};
        {ok, 1, [#get_user_row{name = none}]} -> unnamed;
        {ok, 0, []} -> not_found;
        {error, Reason} -> {error, Reason}
    end.

-spec fetch_mood(Id :: integer()) ->
    {ok, sql:ex_mood()} | not_found | {error, term()}.
fetch_mood(Id) ->
    case sql:get_user(Id) of
        {ok, 1, [#get_user_row{mood = Mood}]} -> {ok, Mood};
        {ok, 0, []} -> not_found;
        {error, Reason} -> {error, Reason}
    end.

-spec add(Id :: integer(), Name :: binary(), Mood :: sql:ex_mood()) ->
    ok | {error, term()}.
add(Id, Name, Mood) ->
    case sql:insert_user(Id, Name, Mood) of
        {ok, 1} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec ids_in_mood(Mood :: sql:ex_mood()) -> {ok, [integer()]} | {error, term()}.
ids_in_mood(Mood) ->
    case sql:list_users_by_mood(Mood) of
        {ok, _Count, Rows} -> {ok, [Row#list_users_by_mood_row.id || Row <- Rows]};
        {error, Reason} -> {error, Reason}
    end.

-spec latest_order_total(Id :: integer()) ->
    {ok, integer()} | no_orders | not_found | {error, term()}.
latest_order_total(Id) ->
    case sql:user_with_latest_order(Id) of
        {ok, _Count, [#user_with_latest_order_row{order_total = {some, Total}} | _]} ->
            {ok, Total};
        {ok, _Count, [#user_with_latest_order_row{order_total = none} | _]} ->
            no_orders;
        {ok, 0, []} ->
            not_found;
        {error, Reason} ->
            {error, Reason}
    end.

-spec event_recorded_at(Id :: uuid:uuid()) ->
    {ok, pg_timestamp:datetime() | infinity | '-infinity'} | not_found | {error, term()}.
event_recorded_at(Id) ->
    case sql:get_event(Id) of
        {ok, 1, [#get_event_row{recorded_at = RecordedAt}]} -> {ok, RecordedAt};
        {ok, 0, []} -> not_found;
        {error, Reason} -> {error, Reason}
    end.
