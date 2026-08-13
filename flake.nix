{
  description = "marmot";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems =
        function: nixpkgs.lib.genAttrs supportedSystems (system: function nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./shell.nix { };
      });

      checks = forAllSystems (
        pkgs:
        let
          checks = nixpkgs.lib.filterAttrs (_: nixpkgs.lib.isDerivation) (
            pkgs.callPackage ./nix/checks.nix { src = self; }
          );
        in
        if pkgs.stdenv.hostPlatform.isDarwin then builtins.removeAttrs checks [ "ct" ] else checks
      );
    };
}
