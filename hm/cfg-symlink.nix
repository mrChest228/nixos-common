{ config, lib, pkgs, vars, com, cur, ... }: {
    # ~/cfg opens the config dir; skipped when the config already lives under the user's home.
    # A symlink, not a bind: rm -r/find/backups in ~ don't descend into it, and git sees the real
    # /etc/nixos path, so safe.directory needs no ~/cfg entries
    home.file."cfg" = lib.mkIf (!(lib.hasPrefix config.home.homeDirectory vars.configPath)) {
        source = config.lib.file.mkOutOfStoreSymlink vars.configPath;
    };
}
