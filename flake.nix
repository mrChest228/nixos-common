{
    # A simple building tree of files set flake for easy imports
    outputs = { ... }: let
        mkFileTree = (path: let
            ls = builtins.readDir path;
            treeWithNulls = builtins.mapAttrs (name: type:
                if type == "directory" then
                    mkFileTree (path + "/${name}")
                else if type == "regular" && builtins.match ".*\\.nix" name != null then
                    path + "/${name}"
                else
                    null
            ) ls;
            tree = builtins.filterAttrs (k: v: v != null) treeWithNulls;

            TOP_LEVEL = { imports = (builtins.filter (x: builtins.isPath x) (builtins.attrValues tree)); };
            ALL = { imports = (TOP_LEVEL.imports ++ (builtins.concatLists (builtins.map (folder: folder.ALL.imports) (builtins.filter (x: builtins.isAttrs x) (builtins.attrValues tree))))); };
        in
            tree // { inherit ALL TOP_LEVEL; }
        );
    in {
        sys = mkFileTree ./sys;
        hm = mkFileTree ./hm;
    };
}
