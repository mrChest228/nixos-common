# update = nix flake update + rebuild; `_` keeps `get (com + /sys/config)` from importing it, laptops import it by name
{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.update ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.update}/bin/update"; options = [ "NOPASSWD" ]; }];
    }];
}
