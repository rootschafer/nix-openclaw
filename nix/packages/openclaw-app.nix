{
  lib,
  stdenvNoCC,
  fetchzip,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-app";
  version = "2026.7.1";

  src = fetchzip {
    url = "https://github.com/openclaw/openclaw/releases/download/v2026.7.1/OpenClaw-2026.7.1.zip";
    hash = "sha256-sAXrwpgs5/IOY/gLPcW9Q4DpL5pppdcZhWwlH9y6q9Y=";
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
