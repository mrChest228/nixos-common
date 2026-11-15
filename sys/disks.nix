# I/O scheduler: bfq on rotating disks only (seeks are expensive there and bfq honours io priorities); ssd/nvme keep the
# kernel's default (none/mq-deadline), a software scheduler only costs them CPU
{ ... }: {
    boot.kernelModules = [ "bfq" ];
    services.udev.extraRules = ''
        ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';
}
