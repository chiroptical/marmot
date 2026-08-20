drop table if exists ex_events;

drop table if exists ex_orders;

drop table if exists ex_users;

drop type if exists ex_mood;

create type ex_mood as enum ('happy', 'sad', 'meh');

create table ex_users (
    id int not null,
    name text,
    mood ex_mood not null
);

create table ex_orders (
    id int not null,
    user_id int not null,
    total int not null
);

create table ex_events (
    id uuid not null,
    happened_on date not null,
    happened_at time not null,
    recorded_at timestamptz not null,
    tags int[] not null
);
