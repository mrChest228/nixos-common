# reconf — commits config changes and switches the Home Manager configurations
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and given a sudo rule by sys/config/packages+security.nix; calls cfg commit and gen clean.
# Usage: reconf [message?] [--no-add (-n)]
# Example:
#   reconf
{ lib, pkgs, vars }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars; };
in (scripts.mkRootFlockCommand "reconf" ''
        ${scripts.nuSwitch}
        def main [message?: string, --no-add(-n)] {
            checkNoForeign
            commitIfChanged "Reconf" $message --no-add=$no_add
            homeSwitchAll
            ^${pkgs.gen}/bin/gen clean
        }
    '').command
