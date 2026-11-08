{ config, lib, pkgs, vars, com, cur, ... }: {
    # chrony instead of systemd-timesyncd (the module turns timesyncd off itself).
    # Small errors are slewed; a step is allowed only for the first 3 measurements (module default makestep 0.1 3),
    # which is what a laptop needs after boot/resume
    networking.timeServers = [ "time.cloudflare.com" "nts.netnod.se" "ptbtime1.ptb.de" ];
    services.chrony = {
        enable = true;
        # NTS: the time packets are authenticated, nobody on the way can shift the clock. Three independent sources,
        # so a lying one is outvoted (one is none, two is a dispute, three is a quorum)
        enableNTS = true;
        # The module's `servers` (default: timeServers) can't take per-server options, so it is emptied and the lines are
        # written here. maxpoll 12 = poll every 1-68 min once settled (default 10 = 17 min; timesyncd 34 min) to spare
        # the public servers; iburst still syncs fast at boot
        servers = [ ];
        extraConfig = lib.concatMapStrings (s: "server ${s} iburst nts maxpoll 12\n") config.networking.timeServers;
    };
}
