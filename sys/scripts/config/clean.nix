{ config, lib, com, pkgs, vars, self, ... }: {
    imports = [ ./lib.nix ];
    config =
        let
            clean = pkgs.writeScriptBin "clean" ''
                #!${pkgs.nushell}/bin/nu
                def main [] {
                    if not (is-admin) { error make { msg: "clean needs root, run it with sudo" } }
                    ^nh clean all --keep 3 --keep-since 3d --optimise
                    ^/run/current-system/bin/switch-to-configuration boot
                }
            '';
        in {
            config-scripts.packages.clean = clean;
            environment.systemPackages = [ clean ];
        };
}
