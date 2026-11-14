{ config, lib, pkgs, vars, com, cur, ... }: {
    swapDevices = [{
        device = "/dev/disk/by-partlabel/${vars.host}-swap";
    }];
    boot.zswap = {
        enable = true;
        compressor = "zstd";
        shrinkerEnabled = true;
    };
    # /tmp in RAM (strictatime, so tmpfiles can age files exactly). Its pages are ordinary swappable memory:
    # under pressure they go to zswap (compressed RAM) and then to the swap partition, never to the root fs
    boot.tmp = {
        useTmpfs = true;
        tmpfsSize = "20%"; # ceiling, not a reservation; a runaway write fails with ENOSPC instead of pushing RAM into swap
    };
    # Shadows systemd's own tmp.conf (the tmpfiles module drops its copy when /etc has a file of the same name):
    # /tmp entries untouched for 2 days are removed, /var/tmp (on disk) keeps the 30-day default
    environment.etc."tmpfiles.d/tmp.conf".text = ''
        q /tmp     1777 root root 2d
        q /var/tmp 1777 root root 30d
    '';
}
