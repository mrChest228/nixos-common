{ config, lib, pkgs, vars, com, cur, ... }: {
    nix = {
        channel.enable = false;
        settings = {
            http-connections = 20; # Number of parallel downloads
            download-attempts = 3;
            max-jobs = 14;         # Number of parallel compilations
            experimental-features = [
                "nix-command" "flakes"
                "pipe-operators"     # a |> f = f a: the data, then its steps left to right (see lib/get.nix); iets has
                                     # it always, the real nix (nix repl, flake check) only with the flag. Not in nixpkgs
                "cgroups"            # use-cgroups
                "auto-allocate-uids" # auto-allocate-uids
            ];

            # Build sandbox: nix's own Linux defaults, written out so a change is a diff here and not a silent new
            # default (the server builds for other machines too). A build sees only its store inputs and /build in
            # private mount/pid/net/ipc/uts namespaces (a fixed-output build keeps the network, its hash guards it)
            sandbox = true;
            sandbox-fallback = false;    # a kernel that can't sandbox fails the build instead of running it outside
            filter-syscalls = true;      # no setuid/setgid files, ACLs, xattrs from a build
            allow-new-privileges = false;
            use-cgroups = true;          # every build in its own cgroup: cancelling kills all of it, detached children too,
                                         # CPU/memory are accounted; uid-range builds (containers, images) need it
            auto-allocate-uids = true;   # a fresh UID from start-id..+id-count per build instead of 32 nixbld* accounts
                                         # (nixpkgs then sets nrBuildUsers = 0 and drops them)
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
        clean = {
            enable = true;
            dates = "02:00"; # For servers. Notebooks run it after the turning on. They don't need to wait the 12 PM
            extraArgs = "--keep 3 --keep-since 3d";
        };
    };

    nix = { # Disable store optimise. It break the bcachefs and its builtin optimisations
        settings.auto-optimise-store = false;
        optimise.automatic = false;
        gc.automatic = false;
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
