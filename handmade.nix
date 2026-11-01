# My lib functions and packages for every host. The host flake does
#   lib.extend (final: prev: handmade.myLibs (com + /lib) final prev)
#   pkgs.appendOverlays [ (handmade.myPkgs (com + /pkgs)) (handmade.myPkgs (cur + /pkgs)) ]
# An entry of a dir is <entry>.nix or <entry>/<name> (function.nix for lib, package.nix for pkgs): a function over
# the args below, its result becomes lib.<entry> / pkgs.<entry>. A subdir without <name> is a group: its entries land
# one level deeper (pkgs.<subdir>.<entry>) on top of what is already there. Names starting with _ or . are skipped.
# `lib` here is nixpkgs' own: the names an overlay produces can't depend on `final`, only their values can
{ lib, vars, com, cur }: let
    visible = entry: !lib.hasPrefix "_" entry && !lib.hasPrefix "." entry;
    isNixFile = entry: type: type != "directory" && lib.hasSuffix ".nix" entry;
    isDir = entry: type: type == "directory";

    # importMy "package.nix" args dir prev: the attrset built from dir; prev holds what its names mean so far
    importMy = name: args: dir: prev: let
        entries = lib.filterAttrs (entry: type: visible entry) (if lib.pathExists dir then builtins.readDir dir else {});

        # concatMapAttrs: every attr -> a small attrset, all of them merged (here it renames foo.nix -> foo)
        files = lib.concatMapAttrs (file: type: {
            ${lib.removeSuffix ".nix" file} = import (dir + "/${file}") args;
        }) (lib.filterAttrs isNixFile entries);

        dirs = lib.mapAttrs (subdir: type: let
            path = dir + "/${subdir}";
            old = prev.${subdir} or {};
        in
            if lib.pathExists (path + "/${name}") then
                import (path + "/${name}") args
            else if !lib.isAttrs old || lib.isDerivation old then
                throw "${toString path}: a group can't replace `${subdir}`, which is not an attrset"
            else if importMy name args path old == {} then
                throw "${toString path}: neither ${name} nor anything to group inside"
            else
                old // importMy name args path old
        ) (lib.filterAttrs isDir entries);

        twice = lib.attrNames (lib.intersectAttrs files dirs);
    in
        if twice != [] then
            throw "${toString dir}: both <entry>.nix and <entry>/ exist for ${lib.concatStringsSep ", " twice}"
        else
            files // dirs;
in {
    myLibs = dir: final: prev:
        importMy "function.nix" { lib = final; } dir prev;

    myPkgs = dir: final: prev:
        importMy "package.nix" { inherit vars com cur; lib = final.lib; pkgs = final; } dir prev;
}
