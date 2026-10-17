{ config, lib, pkgs, vars, com, cur, ... }:
let
    cfg = import ./command.nix { inherit lib pkgs vars com; };
in {
    environment.systemPackages = [ cfg.command ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${cfg.command}/bin/cfg"; options = [ "NOPASSWD" ]; }];
    }];
    systemd.services.cfg-perms = {
        description = "Fix ownership and modes of config repos";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.acl pkgs.coreutils pkgs.findutils pkgs.nushell pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.command}/bin/cfg perms";
        };
    };
    # a root-created hm/<user> must be handed to that user; minimal-chown keeps this from retriggering itself
    systemd.paths.cfg-perms = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = [ "${vars.configPath}/common/hm" "${vars.configPath}/${vars.host}/hm" ];
    };
    systemd.services.cfg-sync = {
        description = "Pull and push the config repos";
        path = [ pkgs.acl pkgs.bash pkgs.coreutils pkgs.findutils pkgs.git pkgs.nix pkgs.nushell pkgs.openssh pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = [
                "${cfg.command}/bin/cfg pull --quiet"
                "${cfg.command}/bin/cfg push --quiet"
            ];
            # syncing never delays real work
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
        };
    };
    systemd.timers.cfg-sync = {
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
        source = pkgs.writeScript "cfg-sync-dispatcher" ''
            #!${pkgs.nushell}/bin/nu -n
            def main [interface: string, action: string] {
                if $action == "up" {
                    ^/run/current-system/sw/bin/systemctl start --no-block cfg-sync.service
                }
            }
        '';
    }];
}
