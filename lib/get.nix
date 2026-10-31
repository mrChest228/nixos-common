{ lib }: let
    visible = name: !lib.hasPrefix "_" name && !lib.hasPrefix "." name;
    nixFiles = recurse: dir: let
        ls = builtins.readDir dir;
    in builtins.concatMap (name:
        let path = dir + "/${name}"; type = ls.${name}; in
        if !visible name then []
        else if type == "directory" then (if recurse then nixFiles true path else [])
        else if lib.hasSuffix ".nix" name then [ path ]
        else []
    ) (builtins.attrNames ls);
in {
    # imports = get [ ... ]: file -> itself, dir -> its top-level .nix files, dir/... -> every .nix below it.
    # Names starting with _ or . are never picked up (a dir named explicitly is still read, only its _/. children are
    # skipped), so _config.nix / _home.nix stay entry points only.
    get = builtins.concatMap (p:
        if !builtins.isPath p then throw "get: expected a path, got ${builtins.typeOf p}"
        else if baseNameOf p == "..." then nixFiles true (dirOf p)
        else if builtins.readFileType p == "directory" then nixFiles false p
        else [ p ]
    );
}
