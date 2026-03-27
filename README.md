marmot
=====

A pure Erlang implementation of [squirrel][squirrel]

Plan
----

- [ ] Implement `from_file`, L107 in src/squirrel/internal/query.gleam
    Given a `Filename :: string`, return `{ok, UntypedQuery}` or `{error, ...}`
- [ ] Implement `infer_types`, L544 src/squirrel/internal/database/postgres.gleam
    Given `UntypedQuery`, returns `{ok, TypedQuery}` or `{error, ...}` 

[squirrel]: https://github.com/giacomocavalieri/squirrel
