-- List every user in a given mood, oldest id first.
select id, name from ex_users where mood = $1 order by id
