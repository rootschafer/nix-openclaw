{
  config,
  lib,
  pkgs,
  ...
}:

let
  openclawLib = import ./lib.nix { inherit config lib pkgs; };
  instanceModule = import ./options-instance.nix { inherit lib openclawLib; };
  pluginCatalog = import ./plugin-catalog.nix;
  authProfileSecretRefModule = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.enum [
          "file"
          "exec"
          "env"
        ];
        description = "SecretRef source kind for this credential.";
      };

      provider = lib.mkOption {
        type = lib.types.str;
        description = "Configured OpenClaw secret provider alias to resolve against.";
      };

      id = lib.mkOption {
        type = lib.types.str;
        description = "Secret id within the selected provider.";
      };
    };
  };

  authProfileModule = lib.types.submodule {
    options = {
      agents = lib.mkOption {
        type = lib.types.either (lib.types.enum [ "all" ]) (lib.types.listOf lib.types.str);
        default = "all";
        description = "Which agents should receive this auth profile. Use \"all\" or a list like [ \"coder\" \"main\" ].";
      };

      type = lib.mkOption {
        type = lib.types.enum [
          "api_key"
          "token"
        ];
        description = "Credential type stored in auth-profiles.json.";
      };

      provider = lib.mkOption {
        type = lib.types.str;
        description = "OpenClaw provider id, for example openrouter or openai.";
      };

      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Plaintext API key. Mutually exclusive with keyRef. Usually not recommended.";
      };

      keyRef = lib.mkOption {
        type = lib.types.nullOr authProfileSecretRefModule;
        default = null;
        description = "SecretRef for API key profiles.";
      };

      token = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Plaintext token. Mutually exclusive with tokenRef. Usually not recommended.";
      };

      tokenRef = lib.mkOption {
        type = lib.types.nullOr authProfileSecretRefModule;
        default = null;
        description = "SecretRef for token profiles.";
      };

      expires = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Optional expiry timestamp in milliseconds since epoch.";
      };
    };
  };

  mkSkillOption = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Skill name (used as the directory name).";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description for the skill frontmatter.";
      };
      homepage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional homepage URL for the skill frontmatter.";
      };
      body = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Optional skill body (markdown).";
      };
      openclaw = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = "Optional openclaw metadata for the skill frontmatter.";
      };
      mode = lib.mkOption {
        type = lib.types.enum [
          "symlink"
          "copy"
          "inline"
        ];
        default = "symlink";
        description = "Install mode for the skill (symlink/copy/inline).";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source path for the skill (required for symlink/copy).";
      };
    };
  };

in
{
  options.programs.openclaw = {
    enable = lib.mkEnableOption "OpenClaw (batteries-included)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openclaw;
      description = "OpenClaw batteries-included package.";
    };

    toolNames = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Override the built-in toolchain names (see nix/tools/extended.nix).";
    };

    excludeTools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tool names to remove from the built-in toolchain.";
    };

    appPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Optional OpenClaw app package (defaults to package if unset).";
    };

    installApp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install OpenClaw.app at the default location.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${openclawLib.homeDir}/.openclaw";
      description = "State directory for OpenClaw (logs, sessions, config).";
    };

    workspaceDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.programs.openclaw.stateDir}/workspace";
      description = "Workspace directory for Openclaw agent skills (defaults to stateDir/workspace).";
    };

    workspace = {
      pinAgentDefaults = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pin agents.defaults.workspace to each instance workspaceDir when unset (prevents falling back to template ~/.openclaw/workspace).";
      };
    };

    documents = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a documents directory containing AGENTS.md, SOUL.md, and TOOLS.md.";
    };

    skills = lib.mkOption {
      type = lib.types.listOf mkSkillOption;
      default = [ ];
      description = "Declarative skills installed into each instance workspace.";
    };

    customPlugins = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Plugin source pointer (e.g., github:owner/repo or path:/...).";
            };
            config = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              description = "Plugin-specific configuration (env/files/etc).";
            };
          };
        }
      );
      default = [ ];
      description = "Custom/community plugins (merged with bundled plugin toggles).";
    };

    bundledPlugins =
      lib.mapAttrs
        (
          name: plugin:
          {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = plugin.defaultEnable or false;
              description = "Enable the ${name} plugin (bundled).";
            };
            config = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              description = "Bundled plugin configuration passed through to ${name} (env/settings).";
            };
          }
        )
        pluginCatalog;

    launchd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run OpenClaw gateway via launchd (macOS).";
    };

    launchd.label = lib.mkOption {
      type = lib.types.str;
      default = "com.steipete.openclaw.gateway";
      description = "launchd label for the default OpenClaw instance.";
    };

    systemd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run OpenClaw gateway via systemd user service (Linux).";
    };

    systemd.unitName = lib.mkOption {
      type = lib.types.str;
      default = "openclaw-gateway";
      description = "systemd user service unit name for the default OpenClaw instance.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceModule);
      default = { };
      description = "Named OpenClaw instances (prod/test).";
    };

    authProfiles = lib.mkOption {
      type = lib.types.attrsOf authProfileModule;
      default = { };
      example = lib.literalExpression ''
        {
          "openrouter:default" = {
            agents = "all";
            type = "api_key";
            provider = "openrouter";
            keyRef = {
              source = "file";
              provider = "openrouter_key_provider";
              id = "default";
            };
          };
        }
      '';
      description = ''
        Declarative auth profiles written to ~/.openclaw/agents/<agent>/agent/auth-profiles.json.

        Each profile can target all agents or a selected subset via the `agents` field.
        This is opt-in and intended primarily for API-key or token-based auth.
        OAuth-style runtime-managed credentials should usually remain unmanaged.
      '';
    };

    exposePluginPackages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add plugin packages to home.packages so CLIs are on PATH.";
    };

    reloadScript = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install openclaw-reload helper for no-sudo config refresh + gateway restart.";
      };
    };

    config = lib.mkOption {
      type = lib.types.submodule { options = openclawLib.generatedConfigOptions; };
      default = { };
      description = "OpenClaw config (schema-typed).";
    };
  };
}
