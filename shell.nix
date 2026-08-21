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
}
