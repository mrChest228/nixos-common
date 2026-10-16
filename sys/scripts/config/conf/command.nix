{ lib, pkgs, vars, com, mkRootCommand, commonNu }:
let
    subcommands = lib.concatStringsSep "\n" [
        (import (com + /sys/scripts/config/conf/commit.nix) { inherit vars; })
        (import (com + /sys/scripts/config/conf/rename.nix) { inherit vars; })
        (import (com + /sys/scripts/config/conf/pull.nix) { inherit vars; })
        (import (com + /sys/scripts/config/conf/push.nix) { inherit vars; })
        (import (com + /sys/scripts/config/conf/perms.nix) { inherit lib pkgs vars; })
    ];
in mkRootCommand "conf" ''
    ${commonNu}
    ${import (com + /sys/scripts/config/conf/lib.nix) { inherit pkgs vars; }}
    ${subcommands}
    # bare `conf` shows the generated help
    def main [] { help main }
''
