{
  beam29Packages,
  fetchFromGitHub,
}:
beam29Packages.erlfmt.overrideAttrs (_: {
  version = "1.8.0-unstable-2026-02-26";
  src = fetchFromGitHub {
    owner = "WhatsApp";
    repo = "erlfmt";
    rev = "50e355e0bb2848a026ddb3f35697396cb6943491";
    hash = "sha256-XS0pHYWQnHe5vg4xPFLwRzysmMCaCtcI2BgUyATdeFU=";
  };
})
