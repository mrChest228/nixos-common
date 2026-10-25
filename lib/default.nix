# common.lib { lib }: every module here (<name>.nix or <name>/default.nix, `_`/`.` names skipped) is
# { lib }: { ... }; their attrsets are merged and the host flake extends nixpkgs lib with the result.
# Only builtins here: the host passes the lib being extended, so its attribute names must not depend on it.
{ lib }:
let
    entries = builtins.readDir ./.;
    hidden = name: builtins.substring 0 1 name == "_" || builtins.substring 0 1 name == ".";
    isModule = name:
        !hidden name && name != "default.nix"
        && (entries.${name} == "directory" && builtins.pathExists (./. + "/${name}/default.nix") || builtins.match ".*\\.nix" name != null);
    modules = builtins.filter isModule (builtins.attrNames entries);
in builtins.foldl' (acc: name: acc // import (./. + "/${name}") { inherit lib; }) {} modules
