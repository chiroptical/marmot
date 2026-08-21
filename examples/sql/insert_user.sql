-- Insert a user. Returns nothing, so the generated function yields {ok, Count}.
insert into ex_users (id, name, mood) values ($1, $2, $3)
