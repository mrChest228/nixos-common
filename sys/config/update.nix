{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.update ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.update}/bin/update"; options = [ "NOPASSWD" ]; }];
    }];
}
