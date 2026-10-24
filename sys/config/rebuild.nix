{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.rebuild ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.rebuild}/bin/rebuild"; options = [ "NOPASSWD" ]; }];
    }];
}
