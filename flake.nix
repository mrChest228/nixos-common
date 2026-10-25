{
    outputs = { ... }: {
        path = ./.; # com in the host flake, a path (not a store string), so com + /sys/x.nix stays a path
        lib = import ./lib; # { lib } -> get/getFiles/getTree, myPkgs; the host flake merges it into nixpkgs lib
    };
}
