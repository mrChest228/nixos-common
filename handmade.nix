# My lib functions and packages for every host. The host flake does
#   lib.extend (final: prev: handmade.myLibs (com + /lib) final prev)
#   pkgs.appendOverlays [ (handmade.myPkgs (com + /pkgs)) (handmade.myPkgs (cur + /pkgs)) ]
# An entry of a dir is <name>.nix or <name>/<main>.nix (function.nix for lib, package.nix for pkgs): a function over
# the args below, its result becomes lib.<name> / pkgs.<name>. A subdir without <main>.nix is a group: its entries land
# one level deeper (pkgs.<dir>.<name>) on top of what is already there. Names starting with _ or . are skipped.
# `lib` here is nixpkgs' own: the names an overlay produces can't depend on `final`, only their values can
{ lib, vars, com, cur }: let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    isNixFile = name: type: type != "directory" && lib.hasSuffix ".nix" name;
    isDir = _: type: type == "directory";

    # importDir "package.nix" args dir prev: the attrset built from dir, prev holds what the names mean so far
    importDir = main: args: dir: prev: let
        entries = lib.filterAttrs (name: _: visible name) (if lib.pathExists dir then builtins.readDir dir else {});

        files = lib.mapAttrs' (name: _:
            lib.nameValuePair (lib.removeSuffix ".nix" name) (import (dir + "/${name}") args)
        ) (lib.filterAttrs isNixFile entries);

        dirs = lib.mapAttrs (name: _: let
            path = dir + "/${name}";
            old = prev.${name} or {};
        in
            if lib.pathExists (path + "/${main}") then
                import (path + "/${main}") args
            else if lib.isAttrs old && !lib.isDerivation old then
                old // importDir main args path old
            else
                throw "${toString path}: a group can't replace `${name}`, which is not an attrset"
        ) (lib.filterAttrs isDir entries);

        twice = lib.attrNames (lib.intersectAttrs files dirs);
    in
        if twice != [] then
            throw "${toString dir}: both <name>.nix and <name>/ exist for ${lib.concatStringsSep ", " twice}"
        else
            files // dirs;
in {
    myLibs = dir: final: prev:
        importDir "function.nix" { lib = final; } dir prev;

    myPkgs = dir: final: prev:
        importDir "package.nix" { inherit vars com cur; lib = final.lib; pkgs = final; } dir prev;
}
