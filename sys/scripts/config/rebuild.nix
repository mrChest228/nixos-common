{ config, lib, com, pkgs, vars, self, ... }:
let
    l = import ./lib.nix { inherit lib pkgs vars; };
    cmd = l.mkRootCommand "rebuild" ''
        ${l.nuLib}
        def main [message?: string] {
            checkNoForeign
            commitIfChanged "Rebuild" $message
            let bootedGen = ((^readlink -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^nh os switch -R -H ${vars.host} ${vars.configPath}/cur
            dropLstGen $bootedGen $lstGen ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            genClean
            # activation may have created users from vars.users; their hm dirs get re-owned now
            ^${l.conf.impl} perms
        }
    '';
in {
    environment.systemPackages = [ cmd.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cmd.command}/bin/rebuild"; options = [ "NOPASSWD" ]; }];
    }];
}
