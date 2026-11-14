# My lib functions and packages for every host. The host flake does
#   lib.extend (final: prev: handmade.myLibs (com + /lib) final prev)
#   pkgs.appendOverlays [ (handmade.myPkgs (com + /pkgs)) (handmade.myPkgs (cur + /pkgs)) ]
# How a dir is read: foo.nix -> lib.foo / pkgs.foo, the file is a function over the args below and its result is the
# value; foo/function.nix (lib) or foo/package.nix (pkgs) -> the same, the other files in foo/ are its own business;
# foo/ without that file -> a group: read the same way one level deeper (pkgs.foo.bar), merged into pkgs.foo if it
# already is an attrset. Names starting with _ or . are skipped. `lib` here is nixpkgs' own: an overlay's attribute
# names can't depend on `final`, only its values can
{ lib, vars, com, cur }: let
    isVisible = entry: !lib.hasPrefix "_" entry && !lib.hasPrefix "." entry;
    isNixFile = entry: type: type != "directory" && lib.hasSuffix ".nix" entry;
    isDir = entry: type: type == "directory";

    # importMy "package.nix" args dir prev: the attrset built from dir; prev holds what its names mean so far.
    # concatMapAttrs: every entry -> a one-attribute set { <name> = <value>; }, all of them merged
    importMy = name: args: dir: prev: let
        entries = (if lib.pathExists dir then builtins.readDir dir else {})
            |> lib.filterAttrs (entry: type: isVisible entry);

        # foo.nix -> { foo = …; }
        files = entries |> lib.filterAttrs isNixFile |> lib.concatMapAttrs (entry: type: {
            ${lib.removeSuffix ".nix" entry} = import (dir + "/${entry}") args;
        });

        # foo/ -> { foo = …; }
        dirs = entries |> lib.filterAttrs isDir |> lib.concatMapAttrs (entry: type: let
            path = dir + "/${entry}";
            old = prev.${entry} or {};
        in {
            ${entry} =
                if lib.pathExists (path + "/${name}") then
                    import (path + "/${name}") args
                else if !lib.isAttrs old || lib.isDerivation old then
                    throw "${toString path}: a group can't replace `${entry}`, which is not an attrset"
                else
                    # a group: what this name already held (nixpkgs or an earlier overlay) plus the dir read one level deeper
                    old // importMy name args path old;
        });

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
