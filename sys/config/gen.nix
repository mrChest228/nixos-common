{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.gen ];
}
