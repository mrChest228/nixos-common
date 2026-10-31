{ config, lib, pkgs, vars, com, cur, ... }: {
    # chrony instead of systemd-timesyncd (the module turns timesyncd off itself).
    # Small errors are slewed; a step is allowed only for the first 3 measurements (module default makestep 0.1 3),
    # which is what a laptop needs after boot/resume
    services.chrony = {
        enable = true;
        # NTS: the time packets are authenticated, nobody on the way can shift the clock. Three independent sources,
        # so a lying one is outvoted (one is none, two is a dispute, three is a quorum). Polled every 1-17 minutes
        enableNTS = true;
        servers = [ "time.cloudflare.com" "nts.netnod.se" "ptbtime1.ptb.de" ];
    };
}
