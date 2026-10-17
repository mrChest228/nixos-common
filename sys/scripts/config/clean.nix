{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
    clean = pkgs.writeScriptBin "clean" ''
        #!${pkgs.nushell}/bin/nu -n
        $env.PATH = [ ${scripts.binPath} ]
        def main [] {
            if not (is-admin) { error make { msg: "clean needs root, run it with sudo" } }
            ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --optimise
            ^/run/current-system/bin/switch-to-configuration boot
        }
    '';
in {
    environment.systemPackages = [ clean ];
}
