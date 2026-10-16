{ config, lib, pkgs, vars, com, cur, ... }:
{
    programs.nix-ld = {
        enable = true;
#         libraries = with pkgs; [
#         ];
    };
}
