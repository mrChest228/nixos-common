# clean — cleans the Nix store in the background: old generations, garbage collection, store optimise, bootloader
# Runs as root; started by a user it re-runs itself through sudo. The work runs in a transient unit (nix-clean) at low
# priority and clean returns at once; `journalctl -u nix-clean -f` follows it. Only old generations, fast: `gen clean`.
# Installed by sys/config/packages+security.nix.
# Usage:
#   clean
# Example:
#   clean
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "clean" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    def main [] {
        # re-runs itself through sudo (which asks for the password) when started by a user
        if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) }
        # Nice is CPU only (optimise hashes the whole store, but waits on the disk, not the CPU); the io class is
        # best-effort, not idle, so the unit keeps moving on a busy disk. An nvme with the `none` scheduler ignores
        # io priorities anyway (only bfq honours them)
        let me = ($env.CURRENT_FILE | path expand)
        ^${pkgs.systemd}/bin/systemd-run --unit nix-clean --description "nix store clean" --collect --quiet --nice 19 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 $me run
        print "Cleaning in the background: journalctl -u nix-clean -f"
    }
    # the unit: generations (keep 3 and 3 days), gc, optimise (identical files hard-linked, see sys/nix.nix), bootloader
    def "main run" [] {
        ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --optimise
        ^/run/current-system/bin/switch-to-configuration boot
    }
''
