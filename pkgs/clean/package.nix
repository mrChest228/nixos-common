# clean — cleans the Nix store and keeps recent system, HM and user-profile generations
# Runs as root; started by a user it re-runs itself through sudo and boots the selected generation
# Installed by sys/config/clean.nix.
# Usage:
#   clean
# Example:
#   clean
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "clean" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    def main [] {
        # re-runs itself through sudo (which asks for the password) when started by a user
        if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) }
        ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --optimise
        ^/run/current-system/bin/switch-to-configuration boot
    }
''
