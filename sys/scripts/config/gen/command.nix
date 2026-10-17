{ lib, pkgs, vars, com }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "gen" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    # root-only subcommands re-run the whole command through sudo (which asks for the password) when started by a user
    def rootOrSudo [...args: string] {
        if not (is-admin) { exec /run/wrappers/bin/sudo ($env.CURRENT_FILE | path expand) ...$args }
    }
    def "main del" [...ids: string] {
        rootOrSudo del ...$ids
        ^/run/current-system/sw/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations ...$ids
        ^/run/current-system/bin/switch-to-configuration boot
    }
    def "main switch" [id: string] {
        rootOrSudo switch $id
        let stc = $"/nix/var/nix/profiles/system-($id)-link/bin/switch-to-configuration"
        ^$stc switch
    }
    def "main clean" [] {
        rootOrSudo clean
        ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --nogc --nogcroots
        ^/run/current-system/bin/switch-to-configuration boot
    }
    def "main list" [] { ^${pkgs.nh}/bin/nh os info }
    def "main ls" [] { ^/run/current-system/sw/bin/nixos-rebuild list-generations }
    def main [] { help main }
''
