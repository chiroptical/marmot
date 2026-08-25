{
  stdenv,
  beam29Packages,
  nixfmt,
  postgresql,
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
    checkPhase = ''
      runHook preCheck
      rebar3 as examples dialyzer
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
