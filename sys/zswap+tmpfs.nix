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
    boot.tmp.useTmpfs = true;
    # Replaces systemd's tmp.conf (same file name wins): /tmp entries untouched for 2 days are removed, /var/tmp (on disk) keeps the 30-day default
    systemd.tmpfiles.settings.tmp = {
        "/tmp".q     = { mode = "1777"; user = "root"; group = "root"; age = "2d"; };
        "/var/tmp".q = { mode = "1777"; user = "root"; group = "root"; age = "30d"; };
    };
}
