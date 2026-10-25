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
                # the NM hook restarts the timer when a link comes up: first run 20-40 s later, not at once;
                # `cfg sync --quiet` itself skips repos fetched less than 90 s ago
                OnActiveSec = "20s";
                OnUnitActiveSec = "2min";
                RandomizedDelaySec = "20s";
                # no WakeSystem: a suspended laptop is not woken for syncing
                AccuracySec = "1m";
            };
        };
    };
    # NetworkManager link events, no connectivity checks (those poll an external URL): a link up restarts the timer,
    # a link down stops it when no default route is left, so nothing is tried without a network
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [{
        type = "basic";
        source = pkgs.writeScript "cfg-sync-dispatcher" ''
            #!${pkgs.nushell}/bin/nu -n
            def main [interface: string, action: string] {
                if $action == "up" {
                    ^/run/current-system/sw/bin/systemctl restart --no-block cfg-sync.timer
                } else if $action == "down" {
                    let routes = (^${pkgs.iproute2}/bin/ip route show default | complete | get stdout | str trim)
                    if ($routes | is-empty) { ^/run/current-system/sw/bin/systemctl stop cfg-sync.timer }
                }
            }
        '';
    }];
}
