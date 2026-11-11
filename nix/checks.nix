{
  stdenv,
  beam29Packages,
  nixfmt,
  postgresql,
  erlang-language-platform,
  postgresqlTestHook,
  treefmt,
  callPackage,
  src,
}:
let
  deps = callPackage ./deps.nix { };
  erlfmt = callPackage ./erlfmt.nix { };

  rebar3Check =
    {
      name,
      nativeBuildInputs ? [ ],
      ...
    }@args:
    stdenv.mkDerivation (
      args
      // {
        inherit src;

        nativeBuildInputs = [
          beam29Packages.erlang
          beam29Packages.rebar3
        ]
        ++ nativeBuildInputs;

        configurePhase = ''
          runHook preConfigure
          export HOME="$NIX_BUILD_TOP"
          cp --no-preserve=all -R ${deps} _checkouts
          runHook postConfigure
        '';

        dontBuild = true;
        doCheck = true;

        installPhase = ''
          runHook preInstall
          touch "$out"
          runHook postInstall
        '';
      }
    );
in
{
  format = stdenv.mkDerivation {
    name = "marmot-format";
    inherit src;
    nativeBuildInputs = [
      erlfmt
      nixfmt
      treefmt
    ];
    dontConfigure = true;
    dontBuild = true;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      treefmt --no-cache --fail-on-change
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      touch "$out"
      runHook postInstall
    '';
  };

  eunit = rebar3Check {
    name = "marmot-eunit";
    checkPhase = ''
      runHook preCheck
      rebar3 eunit
      runHook postCheck
    '';
  };

  dialyzer = rebar3Check {
    name = "marmot-dialyzer";
    postConfigure = ''
      cp --no-preserve=all -R ${beam29Packages.rebar3.src}/apps/rebar _checkouts/rebar
      cp --no-preserve=all -R ${beam29Packages.rebar3.src}/vendor/. _checkouts/
    '';
    checkPhase = ''
      runHook preCheck
      rebar3 as analysis,examples dialyzer
      runHook postCheck
    '';
  };

  plugin = rebar3Check {
    name = "marmot-plugin";
    nativeBuildInputs = [
      postgresql
      postgresqlTestHook
      erlfmt
      erlang-language-platform
    ];
    postgresqlEnableTCP = 1;
    postgresqlExtraSettings = "port = 5432";
    PGUSER = "marmot";
    PGDATABASE = "marmot";
    postgresqlTestUserOptions = "LOGIN PASSWORD 'marmot' SUPERUSER";
    PGO_HOST = "127.0.0.1";
    PGO_PORT = "5432";
    PGO_USER = "marmot";
    PGO_DATABASE = "marmot";
    PGO_PASSWORD = "marmot";
    PGO_POOL_SIZE = "1";
    postgresqlTestSetupPost = ''
      sed 's/^\(host.*\)trust$/\1scram-sha-256/' "$PGDATA/pg_hba.conf" >"$PGDATA/pg_hba.conf.scram"
      mv "$PGDATA/pg_hba.conf.scram" "$PGDATA/pg_hba.conf"
      pg_ctl reload
    '';
    checkPhase = ''
      runHook preCheck
      consumer=$(mktemp -d)
      mkdir -p "$consumer/src" "$consumer/_checkouts/marmot"
      cp -R "$src"/src "$src"/rebar.config "$src"/rebar.lock "$consumer/_checkouts/marmot/"
      cp -R ${deps}/. "$consumer/_checkouts/"
      cp -R "$src/examples/sql" "$consumer/src/"
      cat > "$consumer/rebar.config" <<'CONFIG'
      {deps, [pgo, uuid]}.
      {project_plugins, [marmot]}.
      {marmot, #{directories => ["src/sql"], target_otp => 29}}.
      CONFIG
      cat > "$consumer/src/consumer.app.src" <<'APP'
      {application, consumer, [{vsn, "0.1.0"}, {applications, [kernel, stdlib]}]}.
      APP
      psql -v ON_ERROR_STOP=1 -f "$src/examples/schema.sql"
      cd "$consumer"

      env -u DATABASE_URL -u PGO_USER -u PGO_PASSWORD -u PGO_DATABASE \
          rebar3 help marmot generate
      rebar3 marmot generate
      erlfmt -w src/sql.erl
      diff -u "$src/examples/sql.erl" src/sql.erl
      elp lint --module sql --include-generated --include-erlc-diagnostics --include-eqwalizer-diagnostics
      sed -i 's/target_otp => 29/target_otp => 28/' rebar.config
      rebar3 marmot generate
      elp lint --module sql --include-generated --include-erlc-diagnostics --include-eqwalizer-diagnostics
      runHook postCheck
    '';
  };

  ct = rebar3Check {
    name = "marmot-ct";

    nativeBuildInputs = [
      postgresql
      postgresqlTestHook
    ];

    postgresqlEnableTCP = 1;
    postgresqlExtraSettings = ''
      port = 5432
    '';

    PGUSER = "marmot";
    PGDATABASE = "marmot";
    postgresqlTestUserOptions = "LOGIN PASSWORD 'marmot' SUPERUSER";

    postgresqlTestSetupPost = ''
      sed 's/^\(host.*\)trust$/\1scram-sha-256/' "$PGDATA/pg_hba.conf" >"$PGDATA/pg_hba.conf.scram"
      mv "$PGDATA/pg_hba.conf.scram" "$PGDATA/pg_hba.conf"
      pg_ctl reload
    '';

    PGO_HOST = "127.0.0.1";
    PGO_PORT = "5432";
    PGO_USER = "marmot";
    PGO_DATABASE = "marmot";
    PGO_PASSWORD = "marmot";
    PGO_POOL_SIZE = "1";

    checkPhase = ''
      runHook preCheck
      rebar3 ct
      runHook postCheck
    '';
  };
}
