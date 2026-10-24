# cfg — commits, syncs and fixes permissions of config repos in /etc/nixos (<vars.configPath>)
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule, cfg-sync/cfg-perms services) by sys/config/cfg.nix.
# Called by update, rebuild and reconf for commits and permissions.
# Usage:
#   cfg commit [message] [--host (-h) <host|cur|com>] [--all (-a)] [--single (-s)] [--no-add (-n)] — commit and push changes
#   cfg rename <message> [n] [--host (-h) <host|cur|com>] [--single (-s)] [--help] — rename this or an earlier commit
#     n is negative; omitted/-0 renames HEAD and -1 renames its parent
#   cfg pull [--host (-h) <host|cur|com>] [--quiet (-q)] — fetch and rebase from origin
#   cfg push [--host (-h) <host|cur|com>] [--quiet (-q)] — sync, then push local commits
#   cfg sync [--host (-h) <host|cur|com>] [--all (-a)] [--no-add (-n)] — sync branches, confirming origin rewrites
#   cfg perms — repair config repository permissions
# Examples:
#   cfg commit "niri: blur"
#   cfg rename "niri: blur"
#   cfg rename "niri: blur" -1   # rename the commit before the last one
#   cfg push --host cur
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
    subcommands = lib.concatStringsSep "\n" [
        (import ./commit.nix { inherit vars; })
        (import ./rename.nix { inherit vars; })
        (import ./pull.nix { inherit vars; })
        (import ./push.nix { inherit vars; })
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
