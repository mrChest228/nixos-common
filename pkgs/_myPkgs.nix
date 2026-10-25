# common.myPkgs: overlay from a pkgs directory; `_` keeps the scanner from picking this file up as a package
{ lib, vars, com, cur }:
let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    entriesOf = directory: lib.filterAttrs (name: _: visible name) (builtins.readDir directory);
    isNixFile = name: type: (type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name;
    # <name>.nix -> package
    filePackages = args: directory: entries: lib.mapAttrs' (file: _:
        lib.nameValuePair (lib.removeSuffix ".nix" file) (import (directory + "/${file}") args)
    ) (lib.filterAttrs isNixFile entries);
    # <name>/package.nix -> package; <name>/ without it -> group, merged into an existing attrset of that name
    dirPackages = args: directory: entries: previous: lib.mapAttrs (name: _:
        let
            path = directory + "/${name}";
            old = previous.${name} or {};
            group = if builtins.isAttrs old then old else {};
        in if builtins.pathExists (path + /package.nix) then import (path + /package.nix) args
        else group // scan args path group
    ) (lib.filterAttrs (_: type: type == "directory") entries);
    scan = args: directory: previous:
        let
            entries = entriesOf directory;
            files = filePackages args directory entries;
            dirs = dirPackages args directory entries previous;
            conflicts = builtins.attrNames (builtins.intersectAttrs dirs files);
        in if conflicts != [] then throw "${toString directory}: package/group name collision: ${lib.concatStringsSep ", " conflicts}"
        else files // dirs;
    packageArgs = final: { inherit vars com cur; lib = final.lib; pkgs = final; };
in
# <name>.nix or <name>/package.nix is a package called with { lib, pkgs (= final), vars, com, cur }; directories
# without package.nix are recursive groups. _ and . names are skipped at every level; packages replace prior
# values, groups merge into attrsets.
dir: final: prev: if !builtins.pathExists dir then {} else scan (packageArgs final) dir prev
