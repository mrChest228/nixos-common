# small flake-level helpers for the host flake: common.lib { lib } -> attrset merged into nixpkgs lib
{ lib }: import ./get.nix { inherit lib; } // import ./pkgs.nix { inherit lib; }
