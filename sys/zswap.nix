{ config, lib, pkgs, vars, com, cur, ... }: {
    swapDevices = [{
        device = "/dev/disk/by-partlabel/${vars.host}-swap";
    }];
    boot.zswap = {
        enable = true;
        compressor = "zstd";
        shrinkerEnabled = true;
    };
}
