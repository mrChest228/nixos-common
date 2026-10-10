{ config, lib, com, pkgs, vars, self, ... }:
let
    usersNu = lib.concatMapStringsSep " " (u: "\"${u}\"") vars.users;
in {
    options.config-scripts = {
        mkRootCommand = lib.mkOption {
            type = lib.types.raw;
            readOnly = true;
            default = name: text:
                let
                    # real script lives in the store: sudoers can only point at files users can't edit
                    impl = pkgs.writeScript "${name}-impl" ''
                        #!${pkgs.nushell}/bin/nu
                        use ${../../lib.nu} *
                        ${text}
                    '';
                in {
                    inherit impl;
                    # public command: root -> flock + impl; otherwise re-run itself through sudo
                    # the flock serializes whole runs; git's own index.lock only covers single ops
                    command = pkgs.writeScriptBin name ''
                        #!${pkgs.nushell}/bin/nu
                        def --wrapped main [...args: string] {
                            if (is-admin) {
                                exec ${pkgs.util-linux}/bin/flock /run/nixos-config.lock ${impl} ...$args
                            } else {
                                exec sudo ($env.CURRENT_FILE | path expand) ...$args
                            }
                        }
                    '';
                };
        };
        packages = lib.mkOption { type = lib.types.attrsOf lib.types.package; internal = true; default = { }; };
        nuLib = lib.mkOption { type = lib.types.lines; internal = true; default = ""; };
    };
    config.config-scripts.nuLib = ''
        def commitIfChanged [prefix: string, message?: string] {
            let dirty = (not ((^git -C ${vars.configPath}/cur -c core.fsmonitor=false status --porcelain | complete).stdout | is-empty))
            if $dirty or ($message | is-not-empty) {
                let msg = (if ($message | is-empty) { $"($prefix) (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message })
                # the impl does the work as root; going through the wrapper would deadlock on the flock we hold
                try { ^${config.config-scripts.packages."conf-impl"} commit $msg }
            }
        }
        # root's HM must only come from root-owned, tightly permissioned hm/root dirs: root evaluates
        # these files and the switch runs without a password — a user-writable or ACL'd hm/root is a
        # passwordless path to root. If a check fails, only root's switch is skipped.
        def rootHmSafe [] {
            [ "${vars.configPath}/common/hm/root" "${vars.configPath}/${vars.host}/hm/root" ]
            | all { |d|
                if not ($d | path exists) { true } else {
                    let ownerOk = ((^find $d -maxdepth 0 ! -user root | complete).stdout | is-empty)
                    let writeOk = ((^find $d -maxdepth 0 -perm /022 | complete).stdout | is-empty)
                    let aclOk = ((^${pkgs.acl}/bin/getfacl -cp $d | complete).stdout | lines | where { |l| not ($l =~ '^(user|group|other|mask)::') } | is-empty)
                    $ownerOk and $writeOk and $aclOk
                }
            }
        }
        def homeSwitchAll [] {
            # runuser from root asks no password; sudo env_reset drops NH_FLAKE, hence the explicit flake path
            if (rootHmSafe) {
                with-env { HOME: "/root" } { ^nh home switch ${vars.configPath}/cur -c "root@${vars.host}" }
            } else {
                print $"(ansi red)hm/root is not owned and permissioned for root; skipping root's home switch(ansi rst)"
            }
            for u in [ ${usersNu} ] {
                if ((^id -u $u | complete).exit_code != 0) {
                    print $"(ansi yellow)($u): no such user yet, skipping home switch(ansi rst)"
                    continue
                }
                let uid = ((^id -u $u | complete).stdout | str trim)
                ^runuser -u $u -- env HOME=$"/home/($u)" XDG_RUNTIME_DIR=$"/run/user/($uid)" nh home switch ${vars.configPath}/cur -c $"($u)@${vars.host}"
            }
        }
        # lstGen is the last built generation that was never booted (maybe switched into); deleting its
        # profile link is safe even when switched into: the running system stays a GC root via
        # /nix/var/nix/gcroots/current-system
        def dropLstGen [bootedGen: string, lstGen: string, newGen: string] {
            if ($lstGen == $bootedGen) or ($lstGen == $newGen) { return }
            let lstLinks = (ls /nix/var/nix/profiles
                | where { |e| $e.type == "symlink" and ($e.name | path basename | str starts-with "system-") }
                | where { |e| ((^readlink -f $e.name | complete).stdout | str trim) == $lstGen })
            if (($lstLinks | length) == 1) {
                ^${config.config-scripts.packages.gen}/bin/gen del ($lstLinks.0.name | path basename | str replace -a -r '\D' ''')
            }
        }
    '';
}
