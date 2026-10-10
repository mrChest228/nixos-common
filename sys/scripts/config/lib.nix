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
        commonNu = lib.mkOption { type = lib.types.lines; internal = true; default = ""; };
        nuLib = lib.mkOption { type = lib.types.lines; internal = true; default = ""; };
    };
    config.config-scripts.commonNu = ''
        # always prints the error in red; with --quiet (service) also logs to the journal and notifies the first user
        def reportProblem [repo: string, text: string, --quiet] {
            print -e $"(ansi red)($repo): ($text)(ansi rst)"
            if $quiet {
                ^logger -t nixos-config $"($repo): ($text)"
                try {
                    ^systemd-run --quiet --machine=$"${builtins.head vars.users}@.host" --user ${pkgs.libnotify}/bin/notify-send -u critical "NixOS config" $text
                } catch { }
            }
        }
        # direct subdirs of hm whose owner is none of {root, first user, expected owner} are foreign:
        # never chown/chmod them (perms) and refuse to run anything else while they exist —
        # a stray owned-by-someone dir under hm can become code root evaluates after a passwordless reconf
        def foreignHmDirs [] {
            let firstUser = "${builtins.head vars.users}"
            let users = [ ${usersNu} ]
            mut bad = []
            for repo in (ls ${vars.configPath} | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name) {
                let hm = $"($repo)/hm"
                if not ($hm | path exists) { continue }
                for dir in (^find $hm -mindepth 1 -maxdepth 1 -type d | lines) {
                    let name = ($dir | path basename)
                    let owner = ((^stat -c %U $dir | complete).stdout | str trim)
                    let allowed = if $name == "root" {
                        [ "root" ]
                    } else if ($users | any { |u| $u == $name }) {
                        [ "root" $firstUser $name ]
                    } else {
                        [ "root" $firstUser ]
                    }
                    if not ($allowed | any { |o| $o == $owner }) { $bad = ($bad | append $dir) }
                }
            }
            $bad
        }
        # foreign dirs always go to the journal and the first user's notifications, not only in --quiet
        def checkNoForeign [] {
            let foreign = (foreignHmDirs)
            for d in $foreign {
                reportProblem "conf" $"foreign hm dir ($d): fix its owner and run conf perms" --quiet
            }
            if ($foreign | is-not-empty) { exit 1 }
        }
    '';
    config.config-scripts.nuLib = ''
        ${config.config-scripts.commonNu}
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
