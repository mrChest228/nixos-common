{ config, lib, com, pkgs, vars, self, ... }:
{
    services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
    };
}
