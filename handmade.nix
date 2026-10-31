# My own lib modules and packages, shared by every host. `lib` is the plain nixpkgs lib and only walks directories:
# an overlay's attribute names can't depend on `final`. Everything else gets `final`, so lib modules and packages
# can use each other.
#   handmade = import (common.path + /handmade.nix) { inherit (nixpkgs) lib; inherit vars; com = common.path; cur = ./.; };
#   lib.extend (final: prev: handmade.myLibs (com + /lib) final)
#   pkgs.appendOverlays [ (handmade.myPkgs (com + /pkgs)) (handmade.myPkgs (cur + /pkgs)) ]
{ lib, vars, com, cur }: let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    ls = dir: if builtins.pathExists dir then lib.filterAttrs (name: _: visible name) (builtins.readDir dir) else {};
    isNix = name: type: type != "directory" && lib.hasSuffix ".nix" name;
in {
    # dir/<name>.nix are { lib }: { … }; merged into one attrset for lib.extend
    myLibs = dir: final:
        lib.concatMapAttrs (name: _: import (dir + "/${name}") { lib = final; }) (lib.filterAttrs isNix (ls dir));

    # dir/<name>.nix or dir/<name>/package.nix is a package, called with { lib, pkgs, vars, com, cur } (lib and pkgs are final);
    # it replaces whatever nixpkgs had under that name (pkgs.clean is mine, not the Clean compiler).
    # dir/<name>/ without package.nix is a group: pkgs.<name>.<…>, nested as deep as needed, added to an existing
    # attrset of that name; a group over a package, or <name>.nix next to <name>/, is an error.
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
                if builtins.pathExists (path + /package.nix) then import (path + /package.nix) pkgArgs
                else if !lib.isAttrs old || lib.isDerivation old then throw "${toString path}: a group can't replace the package `${name}`"
                else old // scan path old
            ) (lib.filterAttrs (_: type: type == "directory") entries);
            collisions = lib.attrNames (lib.intersectAttrs dirs packages);
        in
            if collisions != [] then throw "${toString directory}: both <name>.nix and <name>/ exist for: ${lib.concatStringsSep ", " collisions}"
            else packages // dirs;
    in scan dir prev;
}
