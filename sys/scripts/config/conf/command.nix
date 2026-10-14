{ lib, pkgs, vars, mkRootCommand, commonNu }:
let
    subcommands = lib.concatStringsSep "\n" [
        (import ./commit.nix { inherit vars; })
        (import ./rename.nix { inherit vars; })
        (import ./pull.nix { inherit vars; })
        (import ./push.nix { inherit vars; })
        (import ./perms.nix { inherit lib pkgs vars; })
    ];
in mkRootCommand "conf" ''
    ${commonNu}
    ${import ./lib.nix { inherit vars; }}
    ${subcommands}
    # bare `conf` shows the generated help
    def main [] { help main }
''
