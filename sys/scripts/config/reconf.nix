{ config, lib, com, pkgs, vars, self, ... }: {
    imports = [ ./lib.nix ./conf/default.nix ./gen.nix ];
    config =
        let
            cmd = config.config-scripts.mkRootCommand "reconf" ''
                ${config.config-scripts.nuLib}
                def main [] {
                    checkNoForeign
                    commitIfChanged "Reconf"
                    homeSwitchAll
                    ^${config.config-scripts.packages.gen}/bin/gen clean
                }
            '';
        in {
            config-scripts.packages.reconf = cmd.command;
            config-scripts.packages."reconf-impl" = cmd.impl;
            environment.systemPackages = [ cmd.command ];
            security.sudo.extraRules = [{
                groups = [ "wheel" ];
                commands = [{ command = "${cmd.command}/bin/reconf"; options = [ "NOPASSWD" ]; }];
            }];
        };
}
