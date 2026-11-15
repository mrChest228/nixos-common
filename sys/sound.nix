{ config, lib, pkgs, vars, com, cur, ... }:
{
    services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
    };
}
