# cfg — commits, syncs and fixes permissions of config repos in /etc/nixos (<vars.configPath>)
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and given a sudo rule by sys/config/packages+security.nix, cfg-sync/cfg-perms units in services.nix (cfg-sync runs `cfg sync --quiet`).
# Called by update, rebuild and reconf for commits and permissions.
# Usage:
#   cfg commit [message] [--host (-h) <host|cur|com>] [--all (-a)] [--single (-s)] [--no-add (-n)] — commit and push changes
#   cfg rename <message> [n] [--host (-h) <host|cur|com>] [--single (-s)] [--help] — rename this or an earlier commit
#     n is negative; omitted/-0 renames HEAD and -1 renames its parent
#   cfg sync [--host (-h) <host|cur|com>] [--all (-a)] [--branch (-b) <branch>] [--quiet (-q)] — fetch, rebase and push; the only command that may confirm a rewritten history
#   cfg perms — repair config repository permissions
# Examples:
#   cfg commit "niri: blur"
#   cfg rename "niri: blur"
#   cfg rename "niri: blur" -1   # rename the commit before the last one
#   cfg sync --host cur
#   cfg sync --branch server   # that branch in every repo that has it, no checkout
{ lib, pkgs, vars }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars; };
    subcommands = lib.concatStringsSep "\n" [
        (import ./commit.nix { inherit vars; })
        (import ./rename.nix { inherit vars; })
        (import ./sync.nix { inherit vars; })
        (import ./perms.nix { inherit lib pkgs vars; })
    ];
    definitions = lib.concatStringsSep "\n" (map
        (file: import file { inherit pkgs vars; })
        [ ./report.nix ./history.nix ./sync-lib.nix ./inputs.nix ./lib.nix ]);
in (scripts.mkRootFlockCommand "cfg" ''
    ${scripts.nuBase}
    ${definitions}
    ${subcommands}
    # bare `cfg` shows the generated help
    def main [] { help main }
'').command
