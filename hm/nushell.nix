{ config, lib, com, pkgs, vars, self, ... }: {
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
            use ${../sys/lib.nu} *
            def --wrapped nudo [...rest: string] {
                if ($rest | is-empty) { return }

                mut nwRest = ($rest | each { |s|
                    if ($s | str contains " ") { $"\"($s)\"" } else { $s } # Adds " if argument contains spaces
                })
                $nwRest.0 = ($nwRest.0 | str replace '^"|"$' ''') # Remove " from the start and the end of command ("ls | to nuon", for example)

                let cmd = ($nwRest | str join " ")

                sudo nu --config /home/${vars.user}/.config/nushell/config.nu --env-config /home/${vars.user}/.config/nushell/env.nu -c $cmd
            }
        '';
        shellAliases = {
            tp = "trash-put";
        };
    };
}
