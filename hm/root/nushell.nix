{ config, lib, pkgs, vars, com, cur, ... }: {
    programs.nushell = {
        enable = true;
        settings = {
            show_banner = false;
            datetime_format = {
                table = "%Y-%m-%d %H:%M:%S";
            };
            table = {
                padding = {
                    left = 0;
                    right = 0;
                };
                header_on_separator = true;
            };
        };
        envFile.text = ""; # Create the .env file
        extraConfig = ''
            use ${com + "/sys/my-std.nu"} *
        '';
        shellAliases = {
            tp = "trash-put";
        };
    };
}
