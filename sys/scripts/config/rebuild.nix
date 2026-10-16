{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import (com + "/sys/scripts/config/lib.nix") { inherit lib pkgs vars com; };
    cmd = scripts.mkRootCommand "rebuild" ''
        ${scripts.nuLib}
        def main [message?: string] {
            checkNoForeign
            commitIfChanged "Rebuild" $message
            let bootedGen = ((^${pkgs.coreutils}/bin/readlink -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${pkgs.nh}/bin/nh os switch -R -H ${vars.host} ${vars.configPath}/cur
            dropLstGen $bootedGen $lstGen ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            genClean
            # activation may have created users from vars.users; their hm dirs get re-owned now
            ^${scripts.conf.impl} perms
        }
    '';
in {
    environment.systemPackages = [ cmd.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cmd.command}/bin/rebuild"; options = [ "NOPASSWD" ]; }];
    }];
}
