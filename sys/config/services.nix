{ config, lib, pkgs, vars, ... }: {
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
                description = "Sync the config repos";
                serviceConfig = {
                    Type = "oneshot";
                    # --quiet: every local branch, markers instead of repeated catastrophe reports and no
                    # question about a rewritten history (that needs a terminal anyway)
                    ExecStart = "${pkgs.cfg}/bin/cfg sync --quiet";
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
    # NetworkManager reports overall connectivity (not one interface): FULL starts the timer and syncs at once,
    # NONE stops the timer so nothing is tried without a network
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [{
        type = "basic";
        source = pkgs.writeScript "cfg-sync-dispatcher" ''
            #!${pkgs.nushell}/bin/nu -n
            def main [interface: string, action: string] {
                if $action != "connectivity-change" { return }
                match ($env.CONNECTIVITY_STATE? | default "") {
                    "FULL" => { ^/run/current-system/sw/bin/systemctl start --no-block cfg-sync.timer cfg-sync.service }
                    "NONE" => { ^/run/current-system/sw/bin/systemctl stop cfg-sync.timer }
                    _ => {}
                }
            }
        '';
    }];
}
