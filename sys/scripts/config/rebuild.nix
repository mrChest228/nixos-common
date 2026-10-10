{ config, lib, com, pkgs, vars, self, ... }: {
    imports = [ ./lib.nix ./conf ./gen.nix ];
    config =
        let
            cmd = config.config-scripts.mkRootCommand "rebuild" ''
                ${config.config-scripts.nuLib}
                def main [message?: string] {
                    commitIfChanged "Rebuild" $message
                    let bootedGen = ((^readlink -f /run/current-system | complete).stdout | str trim)
                    let lstGen = ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
                    ^nh os switch -R -H ${vars.host} ${vars.configPath}/cur
                    dropLstGen $bootedGen $lstGen ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
                    ^${config.config-scripts.packages.gen}/bin/gen clean
                    # activation may have created users from vars.users; their hm dirs get re-owned now
                    ^${config.config-scripts.packages."conf-impl"} perms
                }
            '';
        in {
            config-scripts.packages.rebuild = cmd.command;
            config-scripts.packages."rebuild-impl" = cmd.impl;
            environment.systemPackages = [ cmd.command ];
            security.sudo.extraRules = [{
                groups = [ "wheel" ];
                commands = [{ command = "${cmd.command}/bin/rebuild"; options = [ "NOPASSWD" ]; }];
            }];
        };
}
