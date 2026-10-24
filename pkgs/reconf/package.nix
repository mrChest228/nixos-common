# reconf — commits config changes and switches the Home Manager configurations
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule) by sys/config/reconf.nix; calls cfg commit and gen clean.
# Usage: reconf
# Example:
#   reconf
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "reconf" ''
        ${scripts.nuSwitch}
        def main [] {
            checkNoForeign
            commitIfChanged "Reconf"
            homeSwitchAll
            ^${pkgs.gen}/bin/gen clean
        }
    '').command
