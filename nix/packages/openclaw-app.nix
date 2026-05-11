{
  lib,
  stdenvNoCC,
  fetchzip,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-app";
  version = "2026.5.7";

  src = fetchzip {
    url = "https://github.com/openclaw/openclaw/releases/download/v2026.5.7/OpenClaw-2026.5.7.zip";
    hash = "sha256-64O1dzadr5R1HiS4DlpbC7En3qyEaibDZS8kKbH7GOo=";
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
