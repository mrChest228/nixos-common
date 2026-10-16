{ pkgs, binPath }:
pkgs.writeScriptBin "gen" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = [ ${binPath} ]
    def "main del" [...ids: string] {
        if not (is-admin) { error make { msg: "gen del needs root, run it with sudo" } }
        ^/run/current-system/sw/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations ...$ids
        ^/run/current-system/bin/switch-to-configuration boot
    }
    def "main switch" [id: string] {
        if not (is-admin) { error make { msg: "gen switch needs root, run it with sudo" } }
        let stc = $"/nix/var/nix/profiles/system-($id)-link/bin/switch-to-configuration"
        ^$stc switch
    }
    def "main clean" [] {
        if not (is-admin) { error make { msg: "gen clean needs root, run it with sudo" } }
        ^${pkgs.nh}/bin/nh clean all --keep 3 --keep-since 3d --nogc --nogcroots
        ^/run/current-system/bin/switch-to-configuration boot
    }
    def "main list" [] { ^${pkgs.nh}/bin/nh os info }
    def "main ls" [] { ^/run/current-system/sw/bin/nixos-rebuild list-generations }
    def main [] { help main }
''
