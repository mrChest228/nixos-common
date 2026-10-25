# the config commands from pkgs/ (built in the host flake); sudo rules are in security.nix, units in services.nix,
# update (the laptop-only one) in update.nix
{ pkgs, ... }: {
    environment.systemPackages = with pkgs; [ cfg gen rebuild reconf clean ];
}
