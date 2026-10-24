{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ../../pkgs/_lib.nix { inherit lib pkgs vars com; };
    clean = pkgs.writeScriptBin "clean" ''
        #!${pkgs.nushell}/bin/nu -n
        $env.PATH = ${scripts.binPathNuList}
        def main [] {
            # re-runs itself through sudo (which asks for the password) when started by a user
            if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) }
            ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --optimise
            ^/run/current-system/bin/switch-to-configuration boot
        }
    '';
in {
    environment.systemPackages = [ clean ];
}
