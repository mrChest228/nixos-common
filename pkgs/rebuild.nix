# rebuild — commits pending config changes and switches to the current NixOS configuration
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and given a sudo rule by sys/config/packages+security.nix; calls cfg commit/perms and gen clean.
# Usage: rebuild [message?] [--no-add (-n)]
# Examples:
#   rebuild
#   rebuild "niri: blur"
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "rebuild" ''
        ${scripts.nuSwitch}
        def main [message?: string, --no-add(-n)] {
            checkNoForeign
            commitIfChanged "Rebuild" $message --no-add=$no_add
            let bootedGen = ((^${scripts.bin.readlink} -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${scripts.bin.readlink} -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            # --impure: see sys/iets.nix (iets reads the locked local common only in impure mode)
            ^${scripts.bin.nh} os switch -R -H ${vars.host} ${vars.configPath}/cur --impure
            dropLstGen $bootedGen $lstGen ((^${scripts.bin.readlink} -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${scripts.bin.gen} clean
            # activation may have created users from vars.users; their hm dirs get re-owned now
            ^${scripts.bin.cfg} perms
        }
    '').command
