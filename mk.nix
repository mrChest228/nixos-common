# The flake-level functions every host needs, imported by path: `import (common.path + /mk.nix) { … }`.
# Takes the host's inputs and returns plain values for its flake.nix: { lib, mkPkgs, myPkgs }.
{ nixpkgs-stable, nixpkgs-unstable, home-manager, vars, com, cur, overlays ? [] }:
let
    hidden = name: builtins.substring 0 1 name == "_" || builtins.substring 0 1 name == ".";
    # com/lib/<name>.nix are { lib }: { … }; merged into nixpkgs lib (builtins only here: the attribute names
    # of a lib.extend overlay must not depend on the lib being extended)
    libModules = builtins.filter (name: !hidden name && builtins.match ".*\\.nix" name != null) (builtins.attrNames (builtins.readDir (com + /lib)));
    mkLib = pkgs: pkgs.lib.extend (final: prev:
        home-manager.lib // builtins.foldl' (acc: name: acc // import (com + "/lib/${name}") { lib = final; }) {} libModules
    );
    lib = mkLib nixpkgs-unstable;

    # Overlay from a pkgs directory: <name>.nix or <name>/package.nix is a package called with
    # { lib, pkgs (= final), vars, com, cur }; directories without package.nix are recursive groups.
    # _ and . names are skipped at every level; packages replace prior values, groups merge into attrsets.
    myPkgs = dir: final: prev:
        let
            args = { inherit vars com cur; lib = final.lib; pkgs = final; };
            visible = name: !hidden name;
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
                    entries = lib.filterAttrs (name: _: visible name) (builtins.readDir directory);
                    files = filePackages directory entries;
                    dirs = dirPackages directory entries previous;
                    conflicts = builtins.attrNames (builtins.intersectAttrs dirs files);
                in if conflicts != [] then throw "${toString directory}: package/group name collision: ${lib.concatStringsSep ", " conflicts}"
                else files // dirs;
        in if builtins.pathExists dir then scan dir prev else {};

    pkgsConfig = arch: {
        hostPlatform = arch;
        config.allowUnfree = true;
    };
    mkPkgsOverlays = pkgs: arch:
        (import pkgs (pkgsConfig arch)).appendOverlays [
            (final: prev: { lib = mkLib pkgs; }) # the extended lib everywhere
        ];
    # unstable + pkgs.stable + common packages + host packages (a host package wins over a common one) + host overlays
    mkPkgs = arch:
        (mkPkgsOverlays nixpkgs-unstable arch).appendOverlays ([
            (final: prev: { stable = mkPkgsOverlays nixpkgs-stable arch; })
            (myPkgs (com + /pkgs))
            (myPkgs (cur + /pkgs))
        ] ++ overlays);
in { inherit lib mkPkgs myPkgs; }
