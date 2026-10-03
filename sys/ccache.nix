{ config, lib, com, pkgs, vars, self, ... }: {
    programs.ccache.enable = true; # Optimizes recompilation of the same files
}
