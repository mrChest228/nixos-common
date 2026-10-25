# update — updates flake inputs and creates a bootable system generation
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed by sys/config/packages.nix, sudo rule in security.nix; calls cfg commit and gen clean.
# Usage: update [message?] [--no-add (-n)]
# Examples:
#   update
#   update "refresh inputs"
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "update" ''
        ${scripts.nuSwitch}
        def main [message?: string, --no-add(-n)] {
            checkNoForeign
            cd ${vars.configPath}/cur
            let update = (^/run/current-system/sw/bin/nix flake update | complete)
            if $update.exit_code != 0 {
                print $update.stdout
                print -e $update.stderr
                error make { msg: "nix flake update failed" }
            }
            commitIfChanged "Update" $message --no-add=$no_add
            let bootedGen = ((^${pkgs.coreutils}/bin/readlink -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            # drivers depending on the new kernel (e.g. nvidia userspace vs the loaded module) break on
            # switch, so the new generation only takes effect after a reboot
            ^${pkgs.nh}/bin/nh os boot -R -H ${vars.host} ${vars.configPath}/cur
            homeSwitchAll
            dropLstGen $bootedGen $lstGen ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${pkgs.gen}/bin/gen clean
            print "Reboot to apply the changes"
        }
    '').command
