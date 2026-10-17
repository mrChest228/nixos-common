{ lib, pkgs, vars, mkRootFlockCommand, commonNu }:
let
    subcommands = lib.concatStringsSep "\n" [
        (import ./commit.nix { inherit vars; })
        (import ./rename.nix { inherit vars; })
        (import ./pull.nix { inherit vars; })
        (import ./push.nix { inherit vars; })
        (import ./perms.nix { inherit lib pkgs vars; })
    ];
in mkRootFlockCommand "cfg" ''
    ${commonNu}
    ${import ./lib.nix { inherit pkgs vars; }}
    ${subcommands}
    # bare `cfg` shows the generated help
    def main [] { help main }
''
