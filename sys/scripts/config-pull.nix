{ config, lib, pkgs, vars, self, ... }:
let
    script = pkgs.writeScriptBin "config-pull" ''
        #!${pkgs.nushell}/bin/nu
        # Run only with sudo!
        # Usage: ./config-pull
        # Load all changes have been made in remote repo with saving the local committed and uncommited changes
        GIT_SSH_COMMAND="ssh -i /root/.ssh/nixos-config -o IdentitiesOnly=yes" git pull --rebase --autostash origin main --quiet
    '';
in {
    environment.etc."nixos/config-pull".source = script;
}
