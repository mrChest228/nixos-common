{ config, lib, com, pkgs, vars, self, ... }: {
    programs = {
        gh = {
            enable = true;
            settings = {
                git_protocol = "ssh";
                color_labels = "enabled";
            };
        };
        git = {
            enable = true;
            settings = {
                user = {
                    name = "mrChest228";
                    email = "gengenm32111111@gmail.com";
                };
                url."ssh://git@github.com/".insteadOf = "https://github.com/";

                init.defaultBranch = "main";
                pull.rebase = false;
            };
        };
    };
}
