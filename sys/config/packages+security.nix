{ pkgs, vars, ... }: {
    environment.systemPackages = with pkgs; [ cfg gen rebuild reconf clean ]; # update is in _update.nix (laptops only)
    # the root-only commands re-run themselves through sudo; gen and clean ask for the password
    security.sudo.extraRules = [{
        groups = [ "wheel" ];
        commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) [
            "${pkgs.cfg}/bin/cfg"
            "${pkgs.rebuild}/bin/rebuild"
            "${pkgs.reconf}/bin/reconf"
        ];
    }];
    # the repos are owned by root but read by users (git refuses a repo owned by someone else otherwise)
    programs.git.config.safe.directory = [ "${vars.configPath}/*" ];
}
