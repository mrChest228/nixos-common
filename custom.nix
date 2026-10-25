# My own additions to lib and pkgs, the same on every host, imported by path: `import (common.path + /custom.nix) { vars; com; cur; }`.
# Returns two overlays; the host puts `lib` into `pkgs.lib.extend` and `pkgs` into its nixpkgs overlays.
{ vars, com, cur }:
let
    hidden = name: builtins.substring 0 1 name == "_" || builtins.substring 0 1 name == ".";
    # com/lib/<name>.nix are { lib }: { … } and get the final lib, so they can use each other.
    # Builtins only here: the attribute names of a lib.extend overlay must not depend on the lib being extended.
    libModules = builtins.filter (name: !hidden name && builtins.match ".*\\.nix" name != null) (builtins.attrNames (builtins.readDir (com + /lib)));

    # Overlay from a pkgs directory: <name>.nix or <name>/package.nix is a package called with
    # { lib, pkgs (= final), vars, com, cur }; directories without package.nix are recursive groups.
    # _ and . names are skipped at every level; packages replace prior values, groups merge into attrsets.
    myPkgs = dir: final: prev:
        let
            inherit (prev) lib;  # prev, not final: an overlay's attribute names must not depend on final
            args = { inherit vars com cur; lib = final.lib; pkgs = final; };
            isNixFile = name: type: (type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name;
            filePackages = directory: entries: lib.mapAttrs' (file: _:
                lib.nameValuePair (lib.removeSuffix ".nix" file) (import (directory + "/${file}") args)
            ) (lib.filterAttrs isNixFile entries);
            dirPackages = directory: entries: previous: lib.mapAttrs (name: _:
                let
                    path = directory + "/${name}";
                    old = previous.${name} or {};
                    group = if builtins.isAttrs old then old else {};
                in if builtins.pathExists (path + /package.nix) then import (path + /package.nix) args
                else group // scan path group
            ) (lib.filterAttrs (_: type: type == "directory") entries);
            scan = directory: previous:
                let
                    entries = lib.filterAttrs (name: _: !hidden name) (builtins.readDir directory);
                    files = filePackages directory entries;
                    dirs = dirPackages directory entries previous;
                    conflicts = builtins.attrNames (builtins.intersectAttrs dirs files);
                in if conflicts != [] then throw "${toString directory}: package/group name collision: ${lib.concatStringsSep ", " conflicts}"
                else files // dirs;
        in if builtins.pathExists dir then scan dir prev else {};
in {
    lib = final: prev: builtins.foldl' (acc: name: acc // import (com + "/lib/${name}") { lib = final; }) {} libModules;
    # common packages first, then the host's: a host package wins over a common one of the same name
    pkgs = final: prev: prev.lib.composeExtensions (myPkgs (com + /pkgs)) (myPkgs (cur + /pkgs)) final prev;
}
