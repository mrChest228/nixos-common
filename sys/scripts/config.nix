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
    # real script: does the work, expects root
    mkImpl = name: pkgs.writeScript "${name}-impl" ''
        #!${pkgs.nushell}/bin/nu
        use ${configLib} *
        ${builtins.readFile ./${name}.nu}
    '';
    # public command: root -> flock + impl; otherwise re-run itself through sudo
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
    systemd.tmpfiles.rules = [
        "Z ${vars.configPath}/common - root root -"
        "Z ${vars.configPath}/nixos-* - root root -"
        "Z ${vars.configPath}/common/hm - ${firstUser} users -"
        "Z ${vars.configPath}/nixos-${vars.host}/hm - ${firstUser} users -"
    ] ++ (builtins.concatMap (user: [
        "Z ${vars.configPath}/common/hm/${user} - ${user} users -"
        "Z ${vars.configPath}/nixos-${vars.host}/hm/${user} - ${user} users -"
    ]) vars.users);
    systemd.services.config-sync = {
        path = [ pkgs.bash pkgs.coreutils pkgs.git pkgs.nix pkgs.nushell pkgs.openssh pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = [
                "${commands.config-pull}/bin/config-pull --quiet"
                "${commands.config-push}/bin/config-push --quiet"
            ];
        };
    };
    systemd.timers.config-sync = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "30min";
        };
    };
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
