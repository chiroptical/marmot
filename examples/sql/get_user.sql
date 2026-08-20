-- Get a user by id.
select id, name, mood from ex_users where id = $1
