{ config, lib, com, pkgs, vars, self, ... }: {
    # ~/cfg opens the config dir; skipped when the config already lives under the user's home
    home.file."cfg" = lib.mkIf (!(lib.hasPrefix config.home.homeDirectory vars.configPath)) {
        source = config.lib.file.mkOutOfStoreSymlink vars.configPath;
    };
}
