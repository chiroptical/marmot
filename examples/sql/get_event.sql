-- Get an event by id.
select id, happened_on, happened_at, recorded_at, tags from ex_events where id = $1
