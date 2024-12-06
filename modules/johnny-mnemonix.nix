{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.johnny-mnemonix;

  # Add new types for Git repository items
  gitItemType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Directory name for the repository";
      };
      url = mkOption {
        type = types.str;
        description = "Git repository URL";
      };
      ref = mkOption {
        type = types.str;
        default = "main";
        description = "Git reference (branch, tag, or commit)";
      };
      # Optional: Add sparse checkout patterns
      sparse = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Sparse checkout patterns (empty for full checkout)";
      };
    };
  };

  # Modified item type to support both strings and git repos
  itemType = types.either types.str gitItemType;

  # Helper to create directories and clone repositories
  mkAreaDirs = areas: let
    mkCategoryDirs = areaId: areaConfig: categoryId: categoryConfig:
      concatMapStrings (itemId: let
        itemConfig = categoryConfig.items.${itemId};
        baseItemPath = "${cfg.baseDir}/${areaId}-${areaConfig.name}/${categoryId}-${categoryConfig.name}/${itemId}";
      in
        if isString itemConfig
        then ''
          mkdir -p "${baseItemPath}-${itemConfig}"
        ''
        else ''
          # Create parent directory if it doesn't exist
          mkdir -p "$(dirname "${baseItemPath}")"

          # Use the name field for the directory
          if [ ! -d "${baseItemPath}-${itemConfig.name}" ]; then
            # Clone the repository
            ${pkgs.git}/bin/git clone ${
            if itemConfig.sparse != []
            then "--sparse"
            else ""
          } \
              --branch ${itemConfig.ref} \
              ${itemConfig.url} "${baseItemPath}-${itemConfig.name}"

            # Configure sparse checkout if needed
            ${optionalString (itemConfig.sparse != []) ''
            cd "${baseItemPath}-${itemConfig.name}"
            ${pkgs.git}/bin/git sparse-checkout set ${concatStringsSep " " itemConfig.sparse}
          ''}
          fi
        '') (attrNames categoryConfig.items);

    mkAreaDir = areaId: areaConfig:
      concatMapStrings (
        categoryId:
          mkCategoryDirs areaId areaConfig categoryId areaConfig.categories.${categoryId}
      ) (attrNames areaConfig.categories);
  in ''
    # Ensure base directory exists first
    mkdir -p "${cfg.baseDir}"

    # Create area directories
    ${concatMapStrings (
      areaId:
        mkAreaDir areaId areas.${areaId}
    ) (attrNames areas)}
  '';

  # Helper to create shell functions
  mkShellFunctions = prefix: ''
    # Basic navigation
    ${prefix}() {
      local base="${cfg.baseDir}"
      if [ -z "$1" ]; then
        cd "$base"
      else
        local target=$(find "$base" -type d -name "*$1*" | head -n 1)
        if [ -n "$target" ]; then
          cd "$target"
        else
          echo "No matching directory found"
          return 1
        fi
      fi
    }

    # Up navigation
    ${prefix}-up() {
      cd ..
    }

    # Listing commands
    ${prefix}ls() {
      ls "${cfg.baseDir}"
    }

    ${prefix}l() {
      ls -l "${cfg.baseDir}"
    }

    ${prefix}ll() {
      ls -la "$@"
    }

    ${prefix}la() {
      ls -la "$@"
    }

    # Find command
    ${prefix}find() {
      if [ -z "$1" ]; then
        echo "Usage: ${prefix}find <pattern>"
        return 1
      fi
      find "${cfg.baseDir}" -type d -name "*$1*"
    }

    # Basic command completion
    if [[ -n "$ZSH_VERSION" ]]; then
      # ZSH completion
      compdef _jm_completion ${prefix}
      compdef _jm_completion ${prefix}ls
      compdef _jm_completion ${prefix}find

      function _jm_completion() {
        local curcontext="$curcontext" state line
        typeset -A opt_args

        case "$words[1]" in
          ${prefix})
            _arguments '1:directory:_jm_dirs'
            ;;
          ${prefix}ls)
            _arguments '1:directory:_jm_dirs'
            ;;
          ${prefix}find)
            _message 'pattern to search for'
            ;;
        esac
      }

      function _jm_dirs() {
        local base="${cfg.baseDir}"
        _files -W "$base" -/
      }

    elif [[ -n "$BASH_VERSION" ]]; then
      # Bash completion
      complete -F _jm_completion ${prefix}
      complete -F _jm_completion ${prefix}ls
      complete -F _jm_completion ${prefix}find

      function _jm_completion() {
        local cur prev
        COMPREPLY=()
        cur="$2"
        prev="$3"
        base="${cfg.baseDir}"

        case "$1" in
          ${prefix})
            COMPREPLY=($(compgen -d "$base/$cur" | sed "s|$base/||"))
            ;;
          ${prefix}ls)
            COMPREPLY=($(compgen -d "$base/$cur" | sed "s|$base/||"))
            ;;
          ${prefix}find)
            # No completion for find pattern
            ;;
        esac
      }
    fi
  '';
in {
  options.johnny-mnemonix = {
    enable = mkEnableOption "johnny-mnemonix";

    baseDir = mkOption {
      type = types.str;
      description = "Base directory for johnny-mnemonix";
    };

    shell = {
      enable = mkEnableOption "shell integration";
      prefix = mkOption {
        type = types.str;
        default = "jm";
        description = "Command prefix for shell integration";
      };
      aliases = mkEnableOption "shell aliases";
      functions = mkEnableOption "shell functions";
    };

    areas = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Name of the area";
          };
          categories = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  description = "Name of the category";
                };
                items = mkOption {
                  type = types.attrsOf itemType;
                  description = "Items in the category (string or git repository)";
                };
              };
            });
            description = "Categories within the area";
          };
        };
      });
      default = {};
      description = "Areas configuration";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.activation.createJohnnyMnemonixDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
        echo "Creating Johnny Mnemonix directories..."
        ${mkAreaDirs cfg.areas}
        echo "Finished creating directories"
      '';

      home.file = {
        ".local/share/johnny-mnemonix/.keep".text = "";
        ".local/share/johnny-mnemonix/shell-functions.sh" = mkIf cfg.shell.enable {
          text = mkShellFunctions cfg.shell.prefix;
          executable = true;
        };
      };

      programs.zsh = mkIf cfg.shell.enable {
        enable = true;
        enableCompletion = true;
        initExtraFirst = ''
          # Source johnny-mnemonix functions
          if [ -f $HOME/.local/share/johnny-mnemonix/shell-functions.sh ]; then
            source $HOME/.local/share/johnny-mnemonix/shell-functions.sh
          fi
        '';
      };
    }
  ]);
}
