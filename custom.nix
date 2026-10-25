# My own additions to lib and pkgs, the same on every host, imported by path:
#   custom = import (common.path + /custom.nix) { lib = nixpkgs.lib; inherit vars; com = common.path; cur = ./.; };
# Returns two overlays (final: prev: { … }); the host puts `lib` into `pkgs.lib.extend` and `pkgs` into its overlays.
# The `lib` argument is the plain nixpkgs lib and is used only to walk directories: the attribute names of an overlay
# must not depend on `final` (nix needs them before it can build `final`). Everything else gets `final`:
# lib modules see the final lib, packages see the final pkgs, so they can use each other.
{ lib, vars, com, cur }:
let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    entriesOf = dir: lib.filterAttrs (name: _: visible name) (builtins.readDir dir);

    # com/lib/<name>.nix are { lib }: { … }
    libModules = builtins.attrNames (lib.filterAttrs (name: _: lib.hasSuffix ".nix" name) (entriesOf (com + /lib)));
    libOverlay = final: prev: lib.foldl' (acc: name: acc // import (com + "/lib/${name}") { lib = final; }) {} libModules;

    # A pkgs directory:
    #   <name>.nix or <name>/package.nix — a package, called with { lib, pkgs, vars, com, cur } (lib and pkgs are final);
    #     it replaces whatever nixpkgs had under that name (so pkgs.clean is mine, not the Clean compiler);
    #   <name>/ without package.nix — a group: pkgs.<name>.<…>, nested as deep as needed; it is added to an existing
    #     attrset of that name (pkgs.gnome.myTool), but must not shadow a package (an error instead).
    # <name>.nix and <name>/ side by side is an error too.
    myPkgs = dir: final: prev:
        let
            args = { inherit vars com cur; lib = final.lib; pkgs = final; };
            scan = directory: previous:
                let
                    entries = entriesOf directory;
                    files = lib.filterAttrs (name: type: (type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name) entries;
                    dirs = lib.filterAttrs (_: type: type == "directory") entries;

                    packages = lib.mapAttrs' (file: _:
                        lib.nameValuePair (lib.removeSuffix ".nix" file) (import (directory + "/${file}") args)
                    ) files;
                    groupsAndDirPackages = lib.mapAttrs (name: _:
                        let
                            path = directory + "/${name}";
                            old = previous.${name} or {};
                        in
                        if builtins.pathExists (path + /package.nix) then import (path + /package.nix) args
                        else if !builtins.isAttrs old || lib.isDerivation old then
                            throw "${toString path}: a group can't replace the package `${name}`"
                        else old // scan path old
                    ) dirs;

                    collisions = builtins.attrNames (builtins.intersectAttrs groupsAndDirPackages packages);
                in
                if collisions != [] then
                    throw "${toString directory}: both <name>.nix and <name>/ exist for: ${lib.concatStringsSep ", " collisions}"
                else packages // groupsAndDirPackages;
        in
        if builtins.pathExists dir then scan dir prev else {};

    # common's packages first, then the host's on top: a host package replaces a common one, a host group extends it
    pkgsOverlay = lib.composeExtensions (myPkgs (com + /pkgs)) (myPkgs (cur + /pkgs));
in {
    lib = libOverlay;
    pkgs = pkgsOverlay;
}
