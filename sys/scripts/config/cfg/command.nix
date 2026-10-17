{ lib, pkgs, vars, com }:
let
    scripts = import ../_lib.nix { inherit lib pkgs vars com; };
    subcommands = lib.concatStringsSep "\n" [
        (import ./commit.nix { inherit vars; })
        (import ./rename.nix { inherit vars; })
        (import ./pull.nix { inherit vars; })
        (import ./push.nix { inherit vars; })
        (import ./perms.nix { inherit lib pkgs vars; })
    ];
in scripts.mkRootFlockCommand "cfg" ''
    ${scripts.nuBase}
    ${import ./lib.nix { inherit pkgs vars; }}
    ${subcommands}
    # bare `cfg` shows the generated help
    def main [] { help main }
''
