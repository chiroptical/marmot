{ pkgs, ... }:
let
  beam = pkgs.beam29Packages;
in
pkgs.mkShell {
  buildInputs = [
    beam.erlang
    (pkgs.callPackage ./nix/erlfmt.nix { })
    beam.rebar3
    pkgs.erlang-language-platform
    pkgs.nixfmt
    pkgs.treefmt
  ];

  PGO_HOST = "127.0.0.1";
  PGO_PORT = "5432";
  PGO_USER = "marmot";
  PGO_DATABASE = "marmot";
  PGO_PASSWORD = "marmot";
  PGO_POOL_SIZE = "1";
}
