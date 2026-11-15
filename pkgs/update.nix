# update — updates flake inputs and creates a bootable system generation
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule) by sys/config/_update.nix; calls cfg commit and gen clean.
# Usage: update [message?] [--no-add (-n)]
# Examples:
#   update
#   update "refresh inputs"
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "update" ''
        ${scripts.nuSwitch}
        def main [message?: string, --no-add(-n)] {
            checkNoForeign
            if not (confirmHuman "update the inputs and build a new boot generation?") { exit 1 }
            cd ${vars.configPath}/cur
            let update = (^${scripts.bin.nix} flake update | complete)
            if $update.exit_code != 0 {
                print $update.stdout
                print -e $update.stderr
                error make { msg: "nix flake update failed" }
            }
            commitIfChanged "Update" $message --no-add=$no_add
            let bootedGen = ((^${scripts.bin.readlink} -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${scripts.bin.readlink} -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            # drivers depending on the new kernel (e.g. nvidia userspace vs the loaded module) break on
            # switch, so the new generation only takes effect after a reboot
            # --impure: see sys/iets.nix (iets reads the locked local common only in impure mode)
            ^${scripts.bin.nh} os boot -R -H ${vars.host} ${vars.configPath}/cur --impure
            homeSwitchAll
            dropLstGen $bootedGen $lstGen ((^${scripts.bin.readlink} -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${scripts.bin.gen} clean
            print "Reboot to apply the changes"
        }
    '').command
