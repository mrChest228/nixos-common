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
            def update [message?: string] {
                cd ${vars.configPath}/cur
                nudo nix flake update
                if (not ((git status -s) | is-empty) or not ($message | is-empty)) {
                    try { config-commit (if ($message | is-empty) { $"Update (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }) }
                }

                let bootedGen = (readlink -f /run/current-system)
                let prvGen = (readlink -f /nix/var/nix/profiles/system)

                nh os boot # Apply the changes after the reboot to a new generation; config-permissions re-applies hm owners at boot
                nh home switch

                let newGen = (readlink -f /nix/var/nix/profiles/system)
                if (($prvGen != $bootedGen) and ($prvGen != $newGen)) {
                    let prvLinks = ((nudo ls -l /nix/var/nix/profiles/system-*-link) | where target == $prvGen)
                    if (($prvLinks | length) == 1) {
                        gen del ($prvLinks.0.name | str replace -a -r '\D' ''')
                    }
                }

                gen clean
            }
            def rebuild [message?: string] {
                cd ${vars.configPath}/cur
                if (not ((git status -s) | is-empty) or not ($message | is-empty)) {
                    try { config-commit (if ($message | is-empty) { $"Rebuild (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }) }
                }

                let bootedGen = (readlink -f /run/current-system)
                let prvGen = (readlink -f /nix/var/nix/profiles/system)

                # config-permissions restarts on switch when the tmpfiles rules changed (e.g. vars.users), re-applying hm owners
                nh os switch

                let newGen = (readlink -f /nix/var/nix/profiles/system)
                if (($prvGen != $bootedGen) and ($prvGen != $newGen)) {
                    let prvLinks = ((nudo ls -l /nix/var/nix/profiles/system-*-link) | where target == $prvGen)
                    if (($prvLinks | length) == 1) {
                        gen del ($prvLinks.0.name | str replace -a -r '\D' ''')
                    }
                }

                gen clean
            }
            def reconf [message?: string] {
                cd ${vars.configPath}/cur
                if (not ((git status -s) | is-empty) or not ($message | is-empty)) {
                    try { config-commit (if ($message | is-empty) { $"Reconf (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }) }
                }
                nh home switch

                gen clean
            }

            def "gen del" [...ids: string] {
                nudo nix-env --profile /nix/var/nix/profiles/system --delete-generations ...$ids
                nudo /run/current-system/bin/switch-to-configuration boot
            }
            def "gen switch" [id: any] {
                nudo $"/nix/var/nix/profiles/system-($id)-link/bin/switch-to-configuration" switch
            }
            def "gen clean" [] {
                nh clean all --keep 3 --keep-since 3d --nogc --nogcroots
                nudo /run/current-system/bin/switch-to-configuration boot
            }
            def clean [] {
                nh clean all --keep 3 --keep-since 3d --optimise
                sudo /run/current-system/bin/switch-to-configuration boot # Update bootloade
            }
        '';
        shellAliases = {
            tp = "trash-put";

            "gen list" = "nh os info";
            "gen-ls" = "nixos-rebuild list-generations";
        };
    };
}
