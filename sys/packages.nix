{ config, lib, pkgs, vars, com, cur, ... }: {
    environment.systemPackages = with pkgs; [
        home-manager # HM command
        nix-output-monitor
        nix-tree
        nixd         # Nix language server
        moreutils # Standart unix utilites needed for bash-scripts
        python3   # For system scripts and tools like amd-debug-tools
    ] ++ (with pkgs.stable; [
    ]);
}
