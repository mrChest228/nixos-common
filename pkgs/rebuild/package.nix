# rebuild — commits pending config changes and switches to the current NixOS configuration
# Runs as root under /run/nixos-config.lock; started by a user it re-runs itself through sudo.
# Installed and wired (sudo rule) by sys/config/rebuild.nix; calls cfg commit/perms and gen clean.
# Usage: rebuild [message?] [--no-add (-n)]
# Examples:
#   rebuild
#   rebuild "niri: blur"
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in (scripts.mkRootFlockCommand "rebuild" ''
        ${scripts.nuSwitch}
        def main [message?: string, --no-add(-n)] {
            checkNoForeign
            commitIfChanged "Rebuild" $message --no-add=$no_add
            let bootedGen = ((^${pkgs.coreutils}/bin/readlink -f /run/current-system | complete).stdout | str trim)
            let lstGen = ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${pkgs.nh}/bin/nh os switch -R -H ${vars.host} ${vars.configPath}/cur
            dropLstGen $bootedGen $lstGen ((^${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | complete).stdout | str trim)
            ^${pkgs.gen}/bin/gen clean
            # activation may have created users from vars.users; their hm dirs get re-owned now
            ^${pkgs.cfg}/bin/cfg perms
        }
    '').command
