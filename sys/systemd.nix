{ config, lib, pkgs, vars, com, cur, ... }: {
    systemd.settings.Manager = {
        DefaultTimeoutStopSec = "30s"; # Services stopping timer before killing during shutting down
        DefaultTimeoutStartSec = "30s";
    };
    services.journald.settings.Journal = {
        SystemMaxUse = lib.mkDefault "512M"; # Total size of /var/log/journal, the oldest files are removed first. TODO: 4G on the server host
        SystemKeepFree = "1G";      # Don't grow while the root fs has less free space than this
    };
}
