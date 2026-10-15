{ config, lib, com, pkgs, vars, self, ... }:
let
    scripts = import ../lib.nix { inherit lib pkgs vars; };
in {
    environment.systemPackages = [ scripts.conf.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${scripts.conf.command}/bin/conf"; options = [ "NOPASSWD" ]; }];
    }];
    systemd.services.conf-perms = {
        description = "Fix ownership and modes of config repos";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.acl pkgs.coreutils pkgs.findutils pkgs.nushell pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = "${scripts.conf.command}/bin/conf perms";
        };
    };
    # a root-created hm/<user> must be handed to that user; minimal-chown keeps this from retriggering itself
    systemd.paths.conf-perms = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = [ "${vars.configPath}/common/hm" "${vars.configPath}/${vars.host}/hm" ];
    };
    systemd.services.conf-sync = {
        description = "Pull and push the config repos";
        path = [ pkgs.acl pkgs.bash pkgs.coreutils pkgs.findutils pkgs.git pkgs.nix pkgs.nushell pkgs.openssh pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = [
                "${scripts.conf.command}/bin/conf pull --quiet"
                "${scripts.conf.command}/bin/conf push --quiet"
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
            #!${pkgs.nushell}/bin/nu -n
            def main [interface: string, action: string] {
                if $action == "up" {
                    ^/run/current-system/sw/bin/systemctl start --no-block conf-sync.service
                }
            }
        '';
    }];
}
