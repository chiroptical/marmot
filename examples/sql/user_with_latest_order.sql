-- A user and their most recent order, if they have one.
select u.id as user_id, o.id as order_id, o.total as order_total
from ex_users u
left join ex_orders o on o.user_id = u.id
where u.id = $1
order by o.id desc
