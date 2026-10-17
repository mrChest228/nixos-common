{ config, lib, pkgs, vars, com, cur, ... }:
{
    environment.systemPackages = [ (import ./command.nix { inherit lib pkgs vars com; }) ];
}
