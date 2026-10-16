{
    outputs = { ... }: {
        path = ./.; # the only export: com in the host flake, a path (not a store string), so com + /sys/x.nix stays a path
    };
}
