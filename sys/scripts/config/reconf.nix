{ config, lib, com, pkgs, vars, self, ... }:
let
    l = import ./lib.nix { inherit lib pkgs vars; };
    cmd = l.mkRootCommand "reconf" ''
        ${l.nuLib}
        def main [] {
            checkNoForeign
            commitIfChanged "Reconf"
            homeSwitchAll
            genClean
        }
    '';
in {
    environment.systemPackages = [ cmd.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cmd.command}/bin/reconf"; options = [ "NOPASSWD" ]; }];
    }];
}
