{ config, lib, com, pkgs, vars, self, ... }: {
    imports = [ ./lib.nix ./conf ./gen.nix ];
    config =
        let
            cmd = config.config-scripts.mkRootCommand "update" ''
                ${config.config-scripts.nuLib}
                def main [message?: string] {
                    cd ${vars.configPath}/cur
                    ^nix flake update
                    commitIfChanged "Update" $message
                    let bootedGen = ((^readlink -f /run/current-system | complete).stdout | str trim)
                    let lstGen = ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
                    # drivers depending on the new kernel (e.g. nvidia userspace vs the loaded module) break on
                    # switch, so the new generation only takes effect after a reboot
                    ^nh os boot -R -H ${vars.host} ${vars.configPath}/cur
                    homeSwitchAll
                    dropLstGen $bootedGen $lstGen ((^readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
                    ^${config.config-scripts.packages.gen}/bin/gen clean
                    print "Reboot to apply the changes"
                }
            '';
        in {
            config-scripts.packages.update = cmd.command;
            config-scripts.packages."update-impl" = cmd.impl;
            environment.systemPackages = [ cmd.command ];
            security.sudo.extraRules = [{
                groups = [ "wheel" ];
                commands = [{ command = "${cmd.command}/bin/update"; options = [ "NOPASSWD" ]; }];
            }];
        };
}
