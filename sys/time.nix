{ config, lib, pkgs, vars, com, cur, ... }: {
    # chrony instead of systemd-timesyncd (the module turns timesyncd off itself).
    # Small errors are slewed; a step is allowed only for the first 3 measurements (module default makestep 0.1 3),
    # which is what a laptop needs after boot/resume
    services.chrony.enable = true;
}
