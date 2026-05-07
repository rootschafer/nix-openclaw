{
  lib,
  stdenvNoCC,
  fetchzip,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-app";
  version = "2026.5.2";

  src = fetchzip {
    url = "https://github.com/openclaw/openclaw/releases/download/v2026.5.2/OpenClaw-2026.5.2.zip";
    hash = "sha256-9ow5VujnMFyDXjlMMNWtB3Kcj7C2vuvSwGl2bYyr/BA=";
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
