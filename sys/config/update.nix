# update = nix flake update + rebuild; not imported on the server, which is updated by hand
{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.update ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.update}/bin/update"; options = [ "NOPASSWD" ]; }];
    }];
}
