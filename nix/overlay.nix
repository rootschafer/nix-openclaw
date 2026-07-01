{
  openclawToolPkgs ? { },
  qmdPkgs ? { },
}:
final: prev:
let
  # qmd has no working x86_64-darwin build (nix-openclaw-tools ships none and
  # the standalone qmd flake's x86_64-darwin package is a fakeHash placeholder),
  # so it stays null there; qmd module features are simply unavailable.
  qmdPackage =
    if prev.stdenv.hostPlatform.isDarwin then
      openclawToolPkgs.qmd or null
    else
      qmdPkgs.qmd or qmdPkgs.default or null;
  packages = import ./packages {
    pkgs = prev;
    openclawToolPkgs = openclawToolPkgs;
    inherit qmdPackage;
  };
  toolNames =
    (import ./tools/extended.nix {
      pkgs = prev;
      openclawToolPkgs = openclawToolPkgs;
    }).toolNames;
  withTools =
    {
      toolNamesOverride ? null,
      excludeToolNames ? [ ],
    }:
    import ./packages {
      pkgs = prev;
      openclawToolPkgs = openclawToolPkgs;
      inherit qmdPackage;
      inherit toolNamesOverride excludeToolNames;
    };
in
packages
// {
  openclawPackages = packages // {
    inherit toolNames withTools;
  };
}
