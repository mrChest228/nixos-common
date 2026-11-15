{ config, lib, pkgs, vars, com, cur, ... }: {
    # iets evaluates (nix, nix-build, nix-shell…), the real nix does the rest (daemon, store, unsupported commands).
    # Module from the host flake. In pure mode it refuses local inputs outside the flake, even common locked by rev,
    # so nh runs with --impure (the lock is still followed, the other pure guards are off)
    iets.classic.enable = true;

    # iets reads only ~/.config/iets/iets.toml (no system file by design), so one root-owned file is linked into
    # every account that runs it: root (rebuild, update, cfg) and vars.users
    # fix-hashes: never rewrite a mismatching fixed-output hash in the .nix file ("ask" by default); the hash is
    # the one check that the download is what was meant. workers: eval threads, the default, written to be found
    # here (once: --iets-option workers N or IETS_WORKERS=N)
    environment.etc."iets.toml".text = ''
        fix-hashes = "never"
        workers = 4
    '';
    systemd.tmpfiles.rules = [ { home = "/root"; user = "root"; } ]
        ++ map (user: { home = "/home/${user}"; inherit user; }) vars.users
        |> lib.concatMap ({ home, user }: [
            "d ${home}/.config 0755 ${user} ${user} - -" # Else the link creates .config as root's in a fresh home
            "L+ ${home}/.config/iets/iets.toml - - - - /etc/iets.toml"
        ]);
}
