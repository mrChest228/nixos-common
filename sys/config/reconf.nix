{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.reconf ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.reconf}/bin/reconf"; options = [ "NOPASSWD" ]; }];
    }];
}
