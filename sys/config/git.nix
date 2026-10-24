{ vars, ... }: {
    programs.git.config.safe.directory = [ "${vars.configPath}/*" ];
}
