{
    outputs = { ... }: {
        path = ./.; # com in the host flake, a path (not a store string), so com + /sys/x.nix stays a path
        lib = import ./lib;                 # { lib } -> get, getFiles, getTree; merged into the host's nixpkgs lib
        myPkgs = import ./pkgs/_myPkgs.nix; # { lib, vars, com, cur } -> dir -> overlay with the packages of that dir
    };
}
