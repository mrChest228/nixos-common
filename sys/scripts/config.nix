{ config, lib, com, pkgs, vars, self, ... }:
let
    firstUser = builtins.head vars.users;
    consts = ''
        export const CONFIG_PATH = "${vars.configPath}"
        export const HOST = "${vars.host}"
        export const FIRST_USER = "${firstUser}"
        export const SSH_COMMAND = "ssh -i /root/.ssh/nixos-config -o IdentitiesOnly=yes"
        export const PULL_PAUSE = 3min
        export const NOTIFY_SEND = "${pkgs.libnotify}/bin/notify-send"
    '';
    configLib = pkgs.writeText "config-lib.nu" (consts + builtins.readFile ./lib.nu);
    # real script lives in the store: sudoers can only point at files users can't edit
    mkImpl = name: pkgs.writeScript "${name}-impl" ''
        #!${pkgs.nushell}/bin/nu
        use ${configLib} *
        ${builtins.readFile ./${name}.nu}
    '';
    # public command: root -> flock + impl; otherwise re-run itself through sudo
    # the flock serializes whole runs; git's own index.lock only covers single ops
    mkCommand = name: pkgs.writeScriptBin name ''
        #!${pkgs.nushell}/bin/nu
        def --wrapped main [...args: string] {
            if (is-admin) {
                exec ${pkgs.util-linux}/bin/flock /run/nixos-config.lock ${mkImpl name} ...$args
            } else {
                exec sudo ($env.CURRENT_FILE | path expand) ...$args
            }
        }
    '';
    names = [ "config-commit" "config-rename" "config-pull" "config-push" ];
    commands = lib.genAttrs names mkCommand;
in {
    environment.systemPackages = (builtins.attrValues commands) ++ [ pkgs.nushell ];
    environment.etc = lib.mapAttrs' (name: _: lib.nameValuePair "nixos/${name}" { source = "${commands.${name}}/bin/${name}"; }) commands;
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = map (name: { command = "${commands.${name}}/bin/${name}"; options = [ "NOPASSWD" ]; }) names;
    }];
    # rule order: root takes everything first, then hm goes to the first user (covers unknown/renamed user dirs), then each user takes their own dir
    systemd.tmpfiles.rules = [
        "Z ${vars.configPath} - root root -"
    ] ++ (builtins.concatMap (repo: [
        "Z ${vars.configPath}/${repo}/hm - ${firstUser} users -"
    ] ++ (builtins.map (user: "Z ${vars.configPath}/${repo}/hm/${user} - ${user} users -") vars.users)) [ "common" vars.host ]);
    # tmpfiles-setup runs only at boot; this reruns on every switch where the rules changed
    systemd.services.config-permissions = {
        wantedBy = [ "multi-user.target" ];
        restartTriggers = config.systemd.tmpfiles.rules;
        serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix ${vars.configPath}";
        };
    };
    systemd.services.config-sync = {
        path = [ pkgs.bash pkgs.coreutils pkgs.git pkgs.nix pkgs.nushell pkgs.openssh pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = [
                "${commands.config-pull}/bin/config-pull --quiet"
                "${commands.config-push}/bin/config-push --quiet"
            ];
            # syncing never delays real work
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
        };
    };
    systemd.timers.config-sync = {
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
        source = pkgs.writeScript "config-sync-dispatcher" ''
            #!${pkgs.nushell}/bin/nu
            def main [interface: string, action: string] {
                if $action == "up" {
                    ^systemctl start --no-block config-sync.service
                }
            }
        '';
    }];
}
