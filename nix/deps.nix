{
  lib,
  beam29Packages,
  fetchFromGitHub,
  runCommand,
}:
let
  hexDeps = lib.mapAttrs (pkg: args: beam29Packages.fetchHex ({ inherit pkg; } // args)) {
    backoff = {
      version = "1.1.6";
      sha256 = "cf0cfff8995fb20562f822e5cc47d8ccf664c5ecdc26a684cbe85c225f9d7c39";
    };
    opentelemetry_api = {
      version = "1.5.0";
      sha256 = "f53ec8a1337ae4a487d43ac89da4bd3a3c99ddf576655d071deed8b56a2d5dda";
    };
    pg_types = {
      version = "0.6.0";
      sha256 = "9949a4849dd13408fa249ab7b745e0d2dfdb9532aee2b9722326e33cd082a778";
    };
  };

  gitDeps = {
    pgo = fetchFromGitHub {
      owner = "chiroptical";
      repo = "pgo";
      rev = "ad293eadf9c34cc68b9c8b2b9c8c45919798f947";
      hash = "sha256-xZsXRLMsWZvoMzKRsydWnVKE3NCOVJRaRYJcLrrz7PM=";
    };
    quickrand = fetchFromGitHub {
      owner = "okeuday";
      repo = "quickrand";
      rev = "65332de501998764f437c3ffe05d744f582d7622";
      hash = "sha256-KKM/ukBP7EyznaMym+j9V9IOuJn/YgkEPewBsZo/Duo=";
    };
    uuid = fetchFromGitHub {
      owner = "okeuday";
      repo = "uuid";
      rev = "7c2d1320c8e61e0fe25a66ecf4761e4b5b5803d6";
      hash = "sha256-ryyV5bVCScjxo+UPDXKGkEYMuCrxgrxVsNicThNsp9o=";
    };
  };
in
runCommand "marmot-deps" { } ''
  mkdir -p "$out"
  ${lib.concatLines (
    lib.mapAttrsToList (name: dep: ''
      cp -R --no-preserve=mode,ownership,timestamps ${dep} "$out/${name}"
    '') (hexDeps // gitDeps)
  )}
''
