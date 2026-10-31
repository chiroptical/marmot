# Run by the plugin derivation after postgresqlTestHook has started PostgreSQL.
# All sources come from Nix inputs; rebar may only fetch the temporary local Git repo.
set -euo pipefail
source_root=$PWD
work=$(mktemp -d)
plugin_source=$work/marmot
consumer=$work/consumer
mkdir -p "$plugin_source" "$consumer/src" "$consumer/_checkouts" "$work/baseline"
cp -R src rebar.config rebar.lock "$plugin_source/"
git -C "$plugin_source" init -q
git -C "$plugin_source" add .
git -C "$plugin_source" -c user.name=Test -c user.email=test@example.invalid commit -qm plugin
revision=$(git -C "$plugin_source" rev-parse HEAD)
cp -R "$MARMOT_DEPS"/. "$consumer/_checkouts/"
cp -R examples/sql "$consumer/src/"
cp examples/example_users.erl "$consumer/src/"
cp examples/sql.erl "$work/baseline/"
cat > "$consumer/src/consumer.app.src" <<'APP'
{application, consumer, [{vsn, "0"}, {applications, [kernel, stdlib, pgo]}, {modules, []}]}.
APP
psql -v ON_ERROR_STOP=1 -f examples/schema.sql
cd "$consumer"

configure() {
    cat > rebar.config <<CONFIG
{project_plugins, [{marmot, {git, "file://$plugin_source", {ref, "$revision"}}}]}.
{deps, [pgo, uuid]}.
$1
CONFIG
}
fail_with() {
    expected=$1
    shift
    if "$@" > "$work/failure.log" 2>&1; then
        cat "$work/failure.log"
        echo "Expected failure: $*" >&2
        exit 1
    fi
    cat "$work/failure.log"
    grep -F "$expected" "$work/failure.log"
    if grep -F 'must-not-be-printed' "$work/failure.log"; then
        echo 'Diagnostic exposed a secret' >&2
        exit 1
    fi
}
compare_output() {
    # This is the declared output scope: top-level Erlang/header artifacts in src,
    # excluding the one handwritten consumer. Compare inventories AND bytes.
    mkdir -p "$work/actual"
    find "$work/actual" -type f -delete
    find src -maxdepth 1 -type f \( -name '*.erl' -o -name '*.hrl' \) \
        ! -name example_users.erl -exec cp '{}' "$work/actual/" \;
    diff -ru "$work/baseline" "$work/actual"
}

configure ''
# Help must load the actual plugin without credentials, and must list its task.
env -u DATABASE_URL -u PGO_USER -u PGO_PASSWORD -u PGO_DATABASE \
    rebar3 help marmot generate | tee "$work/help.log"
grep -F 'rebar3 marmot generate' "$work/help.log"
test ! -e src/sql.erl
# Missing config uses default src scan, running OTP and 5000ms timeout.
rebar3 marmot generate
test ! -d _build/default/lib/consumer/ebin
configure '{marmot, #{target_otp => 29}}.'
rebar3 marmot generate
erlfmt -w src/sql.erl
compare_output
printf '\n%% stale output\n' >> src/sql.erl
if compare_output; then echo 'Stale output passed comparison' >&2; exit 1; fi
cp "$work/baseline/sql.erl" src/sql.erl
printf '%% extra generated artifact\n' > src/extra.hrl
if compare_output; then echo 'Extra output passed comparison' >&2; exit 1; fi
rm src/extra.hrl
mv src/sql.erl "$work/saved.erl"
if compare_output; then echo 'Missing output passed comparison' >&2; exit 1; fi
mv "$work/saved.erl" src/sql.erl
compare_output

rebar3 compile
# Execute the unchanged handwritten example against the generated module.
erl -noshell -pa _build/default/lib/*/ebin _build/default/checkouts/*/ebin -eval '
    {ok, _} = application:ensure_all_started(pgo),
    {ok, _} = pgo:start_pool(default, #{host => os:getenv("PGO_HOST"),
        port => list_to_integer(os:getenv("PGO_PORT")),
        user => os:getenv("PGO_USER"), password => os:getenv("PGO_PASSWORD"),
        database => os:getenv("PGO_DATABASE"), pool_size => 1}),
    ok = example_users:add(1, <<"Ada">>, happy),
    {ok, <<"Ada">>} = example_users:fetch_name(1),
    not_found = example_users:fetch_name(999),
    halt().'

# Explicit paths override even a missing scan root, and normalize dot/parent parts.
configure '{marmot, #{directories => ["src/../src/./sql/"], search_root => "missing", target_otp => 29, connect_timeout => infinity}}.'
rebar3 marmot generate
erlfmt -w src/sql.erl
compare_output
configure "{marmot, #{directories => [\"$consumer/src/sql\"], target_otp => 29}}."
rebar3 marmot generate
# Rebar's effective profile config must be used.
configure '{marmot, #{search_root => "missing"}}.
{profiles, [{generate, [{marmot, #{directories => ["src/sql"], target_otp => 28}}]}]}.'
rebar3 as generate marmot generate
test -s src/sql.hrl
grep -F -- '-include("sql.hrl")' src/sql.erl
mkdir "$work/classic-beams"
erlc -o "$work/classic-beams" src/sql.erl
printf 'protected header\n' > src/sql.hrl
fail_with 'was not written by marmot' rebar3 as generate marmot generate
rm src/sql.hrl

# Root umbrella paths; no per-application configuration or dependency scanning.
mkdir -p apps/demo/src
cp -R "$source_root/examples/sql" apps/demo/src/
configure '{marmot, #{directories => ["apps/demo/src/sql"], target_otp => 29}}.'
rebar3 marmot generate
test -s apps/demo/src/sql.erl

for invalid in \
    'not_a_map' \
    '#{connection => #{password => "must-not-be-printed"}}' \
    '#{pool => default}' \
    '#{unknown => "must-not-be-printed"}' \
    '#{directories => "src/sql"}' \
    '#{search_root => []}' \
    '#{target_otp => 0}' \
    '#{connect_timeout => -1}'; do
    configure "{marmot, $invalid}."
    # Validation must win over absent credentials.
    fail_with 'Invalid marmot' env -u DATABASE_URL -u PGO_USER -u PGO_DATABASE -u PGO_PASSWORD rebar3 marmot generate
done
configure '{marmot, #{directories => ["src/sql", "src/../src/sql/"]}}.'
fail_with 'Duplicate normalized' rebar3 marmot generate
configure '{marmot, #{search_root => "missing"}}.'
fail_with 'is not a directory' rebar3 marmot generate
mkdir empty
configure '{marmot, #{search_root => "empty"}}.'
rebar3 marmot generate

configure '{marmot, #{directories => ["src/sql"], target_otp => 29}}.'
fail_with 'nothing is listening' env -u DATABASE_URL PGO_PORT=1 rebar3 marmot generate
fail_with 'password' env -u DATABASE_URL PGO_PASSWORD=must-not-be-printed rebar3 marmot generate
cp "$work/baseline/sql.erl" src/sql.erl
printf 'handwritten output\n' > src/sql.erl
fail_with 'was not written by marmot' rebar3 marmot generate
cp "$work/baseline/sql.erl" src/sql.erl
printf 'select from broken syntax' > src/sql/broken.sql
printf 'select from more broken syntax' > src/sql/also_broken.sql
fail_with 'broken.sql' rebar3 marmot generate
grep -F 'also_broken.sql' "$work/failure.log"
rm src/sql/broken.sql src/sql/also_broken.sql
rebar3 marmot generate
erlfmt -w src/sql.erl
compare_output
echo 'Marmot plugin integration and regeneration comparisons passed.'
