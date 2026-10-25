# the config commands from pkgs/ (built in the host flake); sudo rules are in security.nix, units in services.nix
{ pkgs, ... }: {
    environment.systemPackages = [ pkgs.cfg pkgs.gen pkgs.update pkgs.rebuild pkgs.reconf pkgs.clean ];
}
