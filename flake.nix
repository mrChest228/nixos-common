{
    # A simple building tree of files in set for easy imports
    outputs = let
        mkFileTree = (path: let
            ls = builtins.readDir path;
            treeWithNulls = builtins.mapAttrs (name: type:
                if type == "directory" then
                    mkFileTree "${path}/${name}"
                else if type == "regular" && builtins.match ".*//.nix" name != null then
                    "${path}/${name}"
                else
                    null
            ) ls;
            tree = builtins.filterAttrs (k: v: v != null) treeWithNulls;

            topLevel = { imports = (builtins.filter (x: builtins.isPath x) (builtins.attrValues tree)); };
            all = { imports = (topLevel.imports ++ (builtins.concatLists (builtins.map (folder: folder.all.imports) (builtins.filter (x: builtins.isAttrs x) (builtins.attrValues tree))))); };
        in
            tree // { inherit all topLevel; }
        );
    in {
        sys = mkFileTree ./sys;
        hm = mkFileTree ./hm;
    };
}
