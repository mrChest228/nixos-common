{ config, lib, pkgs, vars, com, cur, ... }: {
    options.programs.gen.generations = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Generations kept per profile by gen clean and nh-clean (plus everything of the last 3 days)";
    };
}
