{ config, lib, com, pkgs, vars, self, ... }: {
    imports = [ ../lib.nix ./lib.nix ./commit.nix ./rename.nix ./pull.nix ./push.nix ./perms.nix ];
    options.conf = {
        lib = lib.mkOption { type = lib.types.lines; internal = true; default = ""; };
        subcommands = lib.mkOption { type = lib.types.attrsOf lib.types.lines; internal = true; default = { }; };
    };
    config =
        let
            conf = config.config-scripts.mkRootCommand "conf" ''
                ${config.conf.lib}
                ${lib.concatStringsSep "\n" (builtins.attrValues config.conf.subcommands)}
                # bare `conf` shows the generated help
                def main [] { help main }
            '';
        in {
            config-scripts.packages.conf = conf.command;
            config-scripts.packages."conf-impl" = conf.impl;
            environment.systemPackages = [ conf.command pkgs.nushell ];
            environment.etc."nixos/conf".source = "${conf.command}/bin/conf";
            security.sudo.extraRules = [{
                groups = [ "wheel" ];
                commands = [{ command = "${conf.command}/bin/conf"; options = [ "NOPASSWD" ]; }];
            }];
        };
}
