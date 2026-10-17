{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
    cmd = scripts.mkRootFlockCommand "reconf" ''
        ${scripts.nuSwitch}
        def main [] {
            checkNoForeign
            commitIfChanged "Reconf"
            homeSwitchAll
            ^/run/current-system/sw/bin/gen clean
        }
    '';
in {
    environment.systemPackages = [ cmd.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cmd.command}/bin/reconf"; options = [ "NOPASSWD" ]; }];
    }];
}
