{
  openclawToolPkgs ? { },
  qmdPkgs ? { },
}:
final: prev:
let
  qmdPackage =
    if prev.stdenv.hostPlatform.isDarwin then
      # Prefer the nix-openclaw-tools qmd build on Darwin, but fall back to the
      # standalone qmd flake where the tools flake has no build for this system
      # (e.g. x86_64-darwin has no tools outputs).
      openclawToolPkgs.qmd or qmdPkgs.qmd or qmdPkgs.default or null
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
