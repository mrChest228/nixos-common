{ config, lib, pkgs, vars, com, cur, ... }: {
    programs.ccache.enable = true; # Optimizes recompilation of the same files
}
