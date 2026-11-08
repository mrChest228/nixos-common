# clean — the nh-clean job (sys/nix.nix: generations, bootloader, gc, store optimise) now, with the output here. Runs the
# service's own ExecStart in a transient unit nh-clean-now at low priority; Ctrl+C stops it. Root; a user is re-run
# through sudo (NOPASSWD for wheel). Only generations + bootloader, fast: `gen clean`.
# Usage:
#   clean
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "clean" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    def main [] {
        if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) }
        let job = (^${pkgs.systemd}/bin/systemctl show -P ExecStart nh-clean.service | parse -r 'path=(?<path>\S+)' | get 0.path)
        # nice is CPU only; io best-effort 7, not idle, so it keeps moving on a busy disk (nvme with `none` ignores it)
        ^${pkgs.systemd}/bin/systemd-run --pty --wait --collect -q --unit nh-clean-now --nice 19 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 $job
    }
''
