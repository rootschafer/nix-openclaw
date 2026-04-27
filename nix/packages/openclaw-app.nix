{
  lib,
  stdenvNoCC,
  fetchzip,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-app";
  version = "2026.4.24";

  src = fetchzip {
    url = "https://github.com/openclaw/openclaw/releases/download/v2026.4.24/OpenClaw-2026.4.24.zip";
    hash = "sha256-JpJc2A0M+dZy20D2q+0u5XABtRNq12ASYmagZaWoW30=";
    stripRoot = false;
  };

  dontUnpack = true;

  installPhase = "${../scripts/openclaw-app-install.sh}";

  meta = with lib; {
    description = "OpenClaw macOS app bundle";
    homepage = "https://github.com/openclaw/openclaw";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
