{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ./lib.nix { inherit lib pkgs vars com; };
    gen = pkgs.writeScriptBin "gen" ''
        #!${pkgs.nushell}/bin/nu -n
        $env.PATH = [ ${scripts.binPath} ]
        ${scripts.genNu}
        def "main del" [...ids: string] { genDel ...$ids }
        def "main switch" [id: string] {
            if not (is-admin) { error make { msg: "gen switch needs root, run it with sudo" } }
            let stc = $"/nix/var/nix/profiles/system-($id)-link/bin/switch-to-configuration"
            ^$stc switch
        }
        def "main clean" [] { genClean }
        def "main list" [] { ^${pkgs.nh}/bin/nh os info }
        def "main ls" [] { ^/run/current-system/sw/bin/nixos-rebuild list-generations }
        def main [] { help main }
    '';
in {
    environment.systemPackages = [ gen ];
}
