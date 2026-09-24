{
    inputs = {};
    outputs = let
        mkFileTree = path: {
            ls = builtins.readDir path;
            tree = 
        };
    in {
        sys = mkFileTree ./sys;
        hm = mkFileTree ./hm;
    };
}
