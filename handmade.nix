# My lib modules and packages for every host. `lib` is plain nixpkgs lib and only walks directories (an overlay's attribute
# names can't depend on `final`); the modules and packages themselves get `final`, so they can use each other. Usage:
#   lib.extend (final: prev: handmade.myLibs (com + /lib) final);  pkgs.appendOverlays [ (handmade.myPkgs (com + /pkgs)) ]
{ lib, vars, com, cur }: let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    ls = dir: if lib.pathExists dir then lib.filterAttrs (name: _: visible name) (builtins.readDir dir) else {};
    isNix = name: type: type != "directory" && lib.hasSuffix ".nix" name;
in {
    # dir/<name>.nix is { lib }: { … }; all of them merged into one attrset
    myLibs = dir: final:
        lib.concatMapAttrs (name: _: import (dir + "/${name}") { lib = final; }) (lib.filterAttrs isNix (ls dir));

    # dir/<name>.nix or dir/<name>/package.nix: a package { lib, pkgs, vars, com, cur }: … (lib, pkgs are final) replacing
    # nixpkgs' attribute of that name. dir/<name>/ without package.nix: a group pkgs.<name>.<…>, nested, merged into an existing attrset
    myPkgs = dir: final: prev: let
        pkgArgs = { inherit vars com cur; lib = final.lib; pkgs = final; };
        scan = directory: previous: let
            entries = ls directory;
            packages = lib.mapAttrs' (file: _:
                lib.nameValuePair (lib.removeSuffix ".nix" file) (import (directory + "/${file}") pkgArgs)
            ) (lib.filterAttrs isNix entries);
            dirs = lib.mapAttrs (name: _: let
                path = directory + "/${name}";
                old = previous.${name} or {};
            in
                if lib.pathExists (path + /package.nix) then import (path + /package.nix) pkgArgs
                else if !lib.isAttrs old || lib.isDerivation old then throw "${toString path}: a group can't replace the package `${name}`"
                else old // scan path old
            ) (lib.filterAttrs (_: type: type == "directory") entries);
            collisions = lib.attrNames (lib.intersectAttrs dirs packages);
        in
            if collisions != [] then throw "${toString directory}: both <name>.nix and <name>/ exist for: ${lib.concatStringsSep ", " collisions}"
            else packages // dirs;
    in scan dir prev;
}
