{ ... }: {
    programs.nix-index-database.comma.enable = true; # comma itself is built in the host flake (nix override there)
}
