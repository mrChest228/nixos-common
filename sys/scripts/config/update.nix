{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ./lib.nix { inherit lib pkgs vars com; };
    cmd = scripts.mkRootCommand "update" ''
        ${scripts.nuLib}
        def main [message?: string] {
            checkNoForeign
            cd ${vars.configPath}/cur
            ^/run/current-system/sw/bin/nix flake update
            commitIfChanged "Update" $message
            let bootedGen = ((^${pkgs.coreutils}/bin/readlink -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            # drivers depending on the new kernel (e.g. nvidia userspace vs the loaded module) break on
            # switch, so the new generation only takes effect after a reboot
            ^${pkgs.nh}/bin/nh os boot -R -H ${vars.host} ${vars.configPath}/cur
            homeSwitchAll
            dropLstGen $bootedGen $lstGen ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            genClean
            print "Reboot to apply the changes"
        }
    '';
in {
    environment.systemPackages = [ cmd.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cmd.command}/bin/update"; options = [ "NOPASSWD" ]; }];
    }];
}
