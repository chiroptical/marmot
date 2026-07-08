{ pkgs, ... }:
let
  beam = pkgs.beam29Packages;
in
pkgs.mkShell {
  buildInputs = [
    beam.erlang
    beam.rebar3
    pkgs.erlang-language-platform
    pkgs.nixfmt
    pkgs.treefmt
    pkgs.pinact
  ];
}
