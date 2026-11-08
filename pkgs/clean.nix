# clean — nh clean all (old generations, gc, store optimise) and the bootloader, at low priority. Also the body of the
# nightly nh-clean service (sys/nix.nix). Root; a user is re-run through sudo (password). Only generations: `gen clean`.
# Usage:
#   clean       runs it in a transient unit nh-clean-now with the output here; Ctrl+C stops it
#   clean run   the work itself (what the nh-clean service runs)
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "clean" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    def main [] {
        if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) }
        let me = ($env.CURRENT_FILE | path expand)
        # nice is CPU only; io best-effort 7, not idle, so it keeps moving on a busy disk (nvme with `none` ignores it)
        ^${pkgs.systemd}/bin/systemd-run --pty --wait --collect -q --unit nh-clean-now --nice 19 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 $me run
    }
    def "main run" [] {
        ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --optimise
        ^/run/current-system/bin/switch-to-configuration boot
    }
''
