{ config, lib, pkgs, vars, com, cur, ... }: {
    # iets in front of nix (nix, nix-build, nix-shell, nix-instantiate…): its own evaluator, the rest (daemon, store,
    # unsupported commands) falls back to the real nix. The module comes from the host flake (inputs.iets.nixosModules.default).
    # In pure mode iets reads no local input outside the flake, even one locked by rev like common (git+file), so
    # rebuild/update and the home switches run nh with --impure: the lock is still followed, but the other pure-mode
    # guards (getEnv, currentSystem, fetches without a hash) are off too
    iets.classic.enable = true;

    # iets has no machine-wide settings file by design (docs/explanation/history.md: a client builds with the user's
    # settings), only ~/.config/iets/iets.toml, so one root-owned file is linked into every account that runs it:
    # root (rebuild, update, cfg) and vars.users. The accounts don't choose these settings, like the rest of the system
    # fix-hashes: on a fixed-output hash mismatch iets offers to rewrite the hash in the .nix file and build again
    # ("ask" by default, on a terminal only). That hash is the one check that the download is what was meant, so a
    # mismatch stays an error, as in nix
    environment.etc."iets.toml".text = ''
        fix-hashes = "never"
    '';
    systemd.tmpfiles.rules = lib.concatMap ({ home, user }: [
        "d ${home}/.config 0755 ${user} ${user} - -" # Else the link creates .config as root's in a fresh home
        "L+ ${home}/.config/iets/iets.toml - - - - /etc/iets.toml"
    ]) ([ { home = "/root"; user = "root"; } ] ++ map (user: { home = "/home/${user}"; inherit user; }) vars.users);
}
