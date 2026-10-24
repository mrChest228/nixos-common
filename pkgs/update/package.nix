# update — updates flake inputs and creates a bootable system generation
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule) by sys/config/update.nix; calls cfg commit and gen clean.
# Usage: update [message?]
# Examples:
#   update
#   update "refresh inputs"
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "update" ''
        ${scripts.nuSwitch}
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
            ^${pkgs.gen}/bin/gen clean
            print "Reboot to apply the changes"
        }
    '').command
