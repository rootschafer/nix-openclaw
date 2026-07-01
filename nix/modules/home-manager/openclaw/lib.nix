{
  config,
  lib,
  pkgs,
}:

let
  cfg = config.programs.openclaw;
  homeDir = config.home.homeDirectory;
  autoExcludeTools = lib.optionals config.programs.git.enable [ "git" ];
  effectiveExcludeTools = lib.unique (cfg.excludeTools ++ autoExcludeTools);
  toolOverrides = {
    toolNamesOverride = cfg.toolNames;
    excludeToolNames = effectiveExcludeTools;
  };
  toolOverridesEnabled = cfg.toolNames != null || effectiveExcludeTools != [ ];
  overlayPackage = pkgs.openclaw or null;
  toolSets = import ../../../tools/extended.nix ({ inherit pkgs; } // toolOverrides);
  defaultPackage =
    if toolOverridesEnabled && overlayPackage != null && cfg.package == overlayPackage then
      (pkgs.openclawPackages.withTools toolOverrides).openclaw
    else
      cfg.package;
  appPackage = if cfg.appPackage != null then cfg.appPackage else defaultPackage;
  qmdPackage = pkgs.openclawPackages.qmd or null;
  generatedConfigOptions = import ../../../generated/openclaw-config-options.nix { lib = lib; };
  pluginCatalog = import ./plugin-catalog.nix;

  bundledPluginSources =
    let
      openclawToolsRev = "4c1cee3c7eaf68f9de0f756be1484534f5bb5f34";
      openclawToolsNarHash = "sha256-tXWkN1VnwFG8XlRqW/e7VwbKnUfyU9tB7YDm9QHJXTY=";
      openclawTools =
        tool:
        "github:openclaw/nix-openclaw-tools?dir=tools/${tool}&rev=${openclawToolsRev}&narHash=${openclawToolsNarHash}";
    in
    lib.mapAttrs (_name: plugin: plugin.source or (openclawTools plugin.tool)) pluginCatalog;

  # A bundled tool plugin is only usable where nix-openclaw-tools actually
  # ships a build for the host system (e.g. the tools flake has no
  # x86_64-darwin outputs, so its `openclawPlugin system` returns null there).
  # Skip such plugins the same way `tools/extended.nix` drops unavailable
  # tools, rather than letting plugins.nix hard-throw "openclawPlugin is null"
  # and break every default config on that platform.
  bundledPluginAvailableForHost =
    source:
    let
      flake = builtins.getFlake source;
      raw = flake.openclawPlugin or null;
      resolved = if builtins.isFunction raw then raw pkgs.stdenv.hostPlatform.system else raw;
    in
    resolved != null;

  bundledPlugins = lib.filter (p: p != null) (
    lib.mapAttrsToList (
      name: source:
      let
        pluginCfg = cfg.bundledPlugins.${name};
      in
      if (pluginCfg.enable or false) && bundledPluginAvailableForHost source then
        {
          inherit source;
          config = pluginCfg.config or { };
        }
      else
        null
    ) bundledPluginSources
  );

  effectivePlugins = cfg.customPlugins ++ bundledPlugins;

  resolvePath = p: if lib.hasPrefix "~/" p then "${homeDir}/${lib.removePrefix "~/" p}" else p;

  toRelative = p: if lib.hasPrefix "${homeDir}/" p then lib.removePrefix "${homeDir}/" p else p;

in
{
  inherit
    cfg
    homeDir
    toolOverrides
    toolOverridesEnabled
    toolSets
    defaultPackage
    appPackage
    qmdPackage
    generatedConfigOptions
    bundledPluginSources
    bundledPlugins
    effectivePlugins
    resolvePath
    toRelative
    ;
}
