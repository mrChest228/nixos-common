{ config, lib, pkgs, vars, ... }: {
    environment.systemPackages = [ pkgs.cfg ];
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = [{ command = "${pkgs.cfg}/bin/cfg"; options = [ "NOPASSWD" ]; }];
    }];
    systemd = {
        services = {
            cfg-perms = {
                description = "Fix ownership and modes of config repos";
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                    Type = "oneshot";
                    ExecStart = "${pkgs.cfg}/bin/cfg perms";
                };
            };
            cfg-sync = {
                description = "Pull and push the config repos";
                serviceConfig = {
                    Type = "oneshot";
                    # not `cfg sync`: only that command may accept a rewritten history (after a question in the
                    # terminal), the service must never have that path. `cfg push` fetches and rebases every
                    # local branch before pushing, so a separate `cfg pull` would only repeat the work.
                    ExecStart = "${pkgs.cfg}/bin/cfg push --quiet";
                    # syncing never delays real work
                    CPUSchedulingPolicy = "idle";
                    IOSchedulingClass = "idle";
                };
            };
        };
        # a root-created hm/<user> must be handed to that user; minimal-chown keeps this from retriggering itself
        paths.cfg-perms = {
            wantedBy = [ "paths.target" ];
            pathConfig.PathChanged = [ "${vars.configPath}/common/hm" "${vars.configPath}/${vars.host}/hm" ];
        };
        timers.cfg-sync = {
            description = "Sync the config repos every 2 minutes";
            wantedBy = [ "timers.target" ];
            timerConfig = {
                OnBootSec = "2min";
                OnUnitActiveSec = "2min";
                # no WakeSystem: a suspended laptop is not woken for syncing
                AccuracySec = "1m";
            };
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
