{ config, lib, pkgs, vars, com, cur, ... }: {
    nix = {
        channel.enable = false;
        settings = {
            http-connections = 20; # Number of parallel downloads
            download-attempts = 3;
            max-jobs = 14;         # Number of parallel compilations
            experimental-features = [
                "nix-command" "flakes"
                "pipe-operators"     # a |> f = f a, for chains (handmade.nix); iets has it always, the real nix only with the flag
                "cgroups" "auto-allocate-uids"
            ];

            # Build sandbox, nix's Linux defaults written out (the server builds for other machines too): private
            # mount/pid/net/ipc/uts namespaces, only the store inputs and /build visible (a fixed-output build keeps the
            # network, its hash guards it)
            sandbox = true;
            sandbox-fallback = false;    # Was true: a kernel that can't sandbox would build outside it; fail instead
            filter-syscalls = true;      # No setuid/setgid files, ACLs, xattrs from a build
            allow-new-privileges = false;
            use-cgroups = true;          # A build is one cgroup: cancel kills all of it, CPU/memory accounted
            auto-allocate-uids = true;   # A fresh UID per build instead of 32 nixbld* accounts (nrBuildUsers = 0)
            
            use-xdg-base-directories = true;
            allowed-users = [ "root" "@wheel" ]; # For nix-daemon

            substituters = [
                "https://cache.nixos.org"
                "https://nix-community.cachix.org"
                "https://cache.numtide.com" # iets

                "https://niri.cachix.org"

                "https://nix-gaming.cachix.org"
            ];

            trusted-public-keys = [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
                "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="

                "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="

                "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="
            ];
        };
    };
    programs.nh = {
        enable = true;
        flake = "${vars.configPath}/cur";
        clean = { # The nh-clean timer: generations, gc, store optimise; by hand with the output here: `clean`
            enable = true;
            dates = "02:00"; # For servers. Notebooks run it after the turning on. They don't need to wait the 12 PM
            extraArgs = "--keep 3 --keep-since 3d --optimise";
        };
    };

    nix = {
        settings.auto-optimise-store = false; # Would hash and hard-link every path inside the daemon during a switch; nh-clean does it
        optimise.automatic = false;           # The same job as nh-clean --optimise
        gc.automatic = false;                 # nh-clean
    };

    # Nh auto clean + bootloader updating
    systemd = {
        timers.nh-clean.timerConfig = {
            Persistent = true;
            RandomizedDelaySec = "15m";
            AccuracySec = "1m"; # Wait at most 1 minute to group service with other. It needs for battery saving
        };
        services.nh-clean = {
            serviceConfig = {
                CPUSchedulingPolicy = "idle";
                IOSchedulingClass = "idle";
            };
            postStop = "/run/current-system/bin/switch-to-configuration boot || true";
        };
    };
}
