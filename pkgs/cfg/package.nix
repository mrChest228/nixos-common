# cfg — commits, syncs and fixes permissions of config repos in /etc/nixos (<vars.configPath>)
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule, cfg-sync/cfg-perms services) by sys/config/cfg.nix.
# Called by update, rebuild and reconf for commits and permissions.
# Usage:
#   cfg commit [message] [--host (-h) <host|cur|com>] [--all (-a)] [--single (-s)] — commit and push changes
#   cfg rename <message> [n] [--host (-h) <host|cur|com>] [--single (-s)] — rename this or an earlier commit
#   cfg pull [--host (-h) <host|cur|com>] [--quiet (-q)] — fetch and rebase from origin
#   cfg push [--host (-h) <host|cur|com>] [--quiet (-q)] — sync, then push local commits
#   cfg sync [--host (-h) <host|cur|com>] [--all (-a)] — sync branches, confirming origin rewrites
#   cfg perms — repair config repository permissions
# Examples:
#   cfg commit "niri: blur"
#   cfg rename "niri: blur"
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
in (scripts.mkRootFlockCommand "cfg" ''
    ${scripts.nuBase}
    ${import ./lib.nix { inherit pkgs vars; }}
    ${subcommands}
    # bare `cfg` shows the generated help
    def main [] { help main }
'').command
