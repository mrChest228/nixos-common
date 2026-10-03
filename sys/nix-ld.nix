{ config, lib, com, pkgs, vars, self, ... }:
{
    programs.nix-ld = {
        enable = true;
#         libraries = with pkgs; [
#         ];
    };
}
