# gen — lists, switches, deletes and cleans system, HM and user-profile generations
# Root-only actions re-run through sudo (NOPASSWD for wheel) when started by a user; gen does not take the config lock.
# Installed by sys/config/packages+security.nix; update, rebuild and reconf call `gen clean`, switching commands call `gen del`.
# Usage:
#   gen del [...ids]
#   gen switch <id>
#   gen clean
#   gen list
#   gen ls
# Examples:
#   gen list
#   gen clean
{ lib, pkgs, vars, com, cur }:
let
    scripts = import ./_lib.nix { inherit lib pkgs vars com; };
in pkgs.writeScriptBin "gen" ''
    #!${pkgs.nushell}/bin/nu -n
    $env.PATH = ${scripts.binPathNuList}
    # root-only subcommands re-run the whole command through sudo when started by a user
    def rootOrSudo [...args: string] {
        if not (is-admin) { exec ${scripts.bin.sudo} ($env.CURRENT_FILE | path expand) ...$args }
    }
    ${scripts.nuConfirmHuman}
    # del and switch change what the machine boots and what it can roll back to: a person confirms with the password.
    # Started by a config command holding the lock (rebuild/update drop the unbooted generation) nobody is asked
    def confirmUnlessLocked [prompt: string] {
        if ($env.NIXOS_CONFIG_LOCKED? != "1") and not (confirmHuman $prompt) { exit 1 }
    }
    def "main del" [...ids: string] {
        rootOrSudo del ...$ids
        confirmUnlessLocked $"delete generations ($ids | str join ' ')?"
        ^${scripts.bin."nix-env"} --profile /nix/var/nix/profiles/system --delete-generations ...$ids
        ^${scripts.bin."switch-to-configuration"} boot
    }
    def "main switch" [id: string] {
        rootOrSudo switch $id
        confirmUnlessLocked $"switch to generation ($id)?"
        let stc = $"/nix/var/nix/profiles/system-($id)-link/bin/switch-to-configuration"
        ^$stc switch
    }
    # only deletes old generations (system, HM, user profiles), no garbage collection; the store is cleaned by clean.
    # Keeps vars.generations (default 5) per profile and everything of the last 3 days
    def "main clean" [] {
        rootOrSudo clean
        ^${scripts.bin.nh} clean all --keep ${toString (vars.generations or 5)} --keep-since 3d --no-gc --no-gcroots
        ^${scripts.bin."switch-to-configuration"} boot
    }
    def "main list" [] { ^${scripts.bin.nh} os info }
    def "main ls" [] { ^${scripts.bin."nixos-rebuild"} list-generations }
    def main [] { help main }
''
