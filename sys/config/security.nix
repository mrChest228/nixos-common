{ pkgs, vars, ... }: {
    # the root-only commands re-run themselves through sudo; gen and clean ask for the password
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) [
            "${pkgs.cfg}/bin/cfg"
            "${pkgs.update}/bin/update"
            "${pkgs.rebuild}/bin/rebuild"
            "${pkgs.reconf}/bin/reconf"
        ];
    }];
    # the repos are owned by users but read by root
    programs.git.config.safe.directory = [ "${vars.configPath}/*" ];
}
