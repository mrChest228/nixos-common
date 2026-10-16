{ config, lib, pkgs, vars, com, cur, ... }:
let
    scripts = import ../lib.nix { inherit lib pkgs vars com; };
in {
    environment.systemPackages = [ scripts.gen ];
}
