{ config, lib, com, pkgs, vars, self, ... }: {
    systemd.services.conf-sync = {
        description = "Pull and push the config repos";
        path = [ pkgs.acl pkgs.bash pkgs.coreutils pkgs.findutils pkgs.git pkgs.nix pkgs.nushell pkgs.openssh pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = [
                "${config.config-scripts.packages.conf}/bin/conf pull --quiet"
                "${config.config-scripts.packages.conf}/bin/conf push --quiet"
            ];
            # syncing never delays real work
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
        };
    };
    systemd.timers.conf-sync = {
        description = "Sync the config repos every 2 minutes";
        wantedBy = [ "timers.target" ];
        timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "2min";
            # no WakeSystem: a suspended laptop is not woken for syncing
            AccuracySec = "1m";
        };
    };
    # NetworkManager fires this on every "up" (boot, wifi, ethernet, usb); the service then pulls and pushes
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [{
        type = "basic";
        source = pkgs.writeScript "conf-sync-dispatcher" ''
            #!${pkgs.nushell}/bin/nu
            def main [interface: string, action: string] {
                if $action == "up" {
                    ^systemctl start --no-block conf-sync.service
                }
            }
        '';
    }];
}
