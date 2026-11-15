{ lib, pkgs, vars, com }: rec {
    # every external the scripts run, by absolute path: store paths for packages, the running system's for what must
    # match it (nix, systemctl, switch-to-configuration), the setuid wrapper for sudo
    bin = {
        chown = "${pkgs.coreutils}/bin/chown";
        chmod = "${pkgs.coreutils}/bin/chmod";
        stat = "${pkgs.coreutils}/bin/stat";
        readlink = "${pkgs.coreutils}/bin/readlink";
        id = "${pkgs.coreutils}/bin/id";
        env = "${pkgs.coreutils}/bin/env";
        find = "${pkgs.findutils}/bin/find";
        flock = "${pkgs.util-linux}/bin/flock";
        logger = "${pkgs.util-linux}/bin/logger";
        runuser = "${pkgs.util-linux}/bin/runuser";
        getfacl = "${pkgs.acl}/bin/getfacl";
        setfacl = "${pkgs.acl}/bin/setfacl";
        git = "${pkgs.git}/bin/git";
        ssh = "${pkgs.openssh}/bin/ssh";
        nh = "${pkgs.nh}/bin/nh";
        gen = "${pkgs.gen}/bin/gen";
        cfg = "${pkgs.cfg}/bin/cfg";
        "notify-send" = "${pkgs.libnotify}/bin/notify-send";
        systemctl = "/run/current-system/sw/bin/systemctl";
        "systemd-run" = "/run/current-system/sw/bin/systemd-run";
        nix = "/run/current-system/sw/bin/nix";
        "nix-env" = "/run/current-system/sw/bin/nix-env";
        "nixos-rebuild" = "/run/current-system/sw/bin/nixos-rebuild";
        "switch-to-configuration" = "/run/current-system/bin/switch-to-configuration";
        sudo = "/run/wrappers/bin/sudo";
    };
    # nushell list literal of the users whose Home Manager these scripts switch and whose hm/<user> dirs they check
    hmUsersNuList = "[ ${lib.concatMapStringsSep " " (u: "\"${u}\"") vars.users} ]";
    # PATH for root scripts as a nushell list literal. sudo keeps the caller's PATH on NixOS, so the impl
    # replaces it: a fake nix/git earlier in the user's PATH would otherwise run as root. Everything the
    # scripts run themselves is called by full path; PATH only serves programs those start by name:
    #   /run/current-system/sw/bin  nh runs nix and nixos-rebuild by name; nix/HM activation may call systemctl
    binPathNuList = "[ \"/run/current-system/sw/bin\" ]";
    # Command that may only run as root and never alongside another config command.
    # Started by a non-root user it re-runs itself through sudo (so sudo asks for the password unless a
    # NOPASSWD rule matches); as root it runs the impl under flock /run/nixos-config.lock. flock waits
    # (no -n) until the lock is free, also in services; it only protects against other commands, not
    # against git run by hand. A command started by one that already holds the lock (rebuild -> cfg perms)
    # sees NIXOS_CONFIG_LOCKED and skips the second flock, which would deadlock; sudo's env_reset keeps
    # users from setting that variable themselves
    mkRootFlockCommand = name: text: rec {
        # real script lives in the store: sudoers can only point at files users can't edit
        impl = pkgs.writeScript "${name}-impl" ''
            #!${pkgs.nushell}/bin/nu -n
            $env.PATH = ${binPathNuList}
            use ${com + /sys/my-std.nu} *
            ${text}
        '';
        command = pkgs.writeScriptBin name ''
            #!${pkgs.nushell}/bin/nu -n
            def --wrapped main [...args: string] {
                if not (is-admin) {
                    exec ${bin.sudo} ($env.CURRENT_FILE | path expand) ...$args
                } else if ($env.NIXOS_CONFIG_LOCKED? == "1") {
                    exec ${impl} ...$args
                } else {
                    $env.NIXOS_CONFIG_LOCKED = "1"
                    exec ${bin.flock} /run/nixos-config.lock ${impl} ...$args
                }
            }
        '';
    };
    # The person at the terminal proves it is a person: sudo asks the caller's password, ignoring any cached
    # credentials (-k). Runs as the caller, because root is never asked; a genuine root session (no SUDO_USER)
    # has already proven itself at login. Without a terminal there is nobody to ask: false
    nuConfirmHuman = ''
        def confirmHuman [prompt: string] {
            if not (is-terminal --stdin) { return false }
            let sudoUser = ($env.SUDO_USER? | default "")
            if ($sudoUser | is-empty) { return true }
            try {
                ^${bin.runuser} -u $sudoUser -- ${bin.sudo} -k -v -p $"($prompt) [password for ($sudoUser)]: "
                true
            } catch { false }
        }
    '';
    # nushell text shared by every config command: safe git, reporting, foreign hm dir checks
    nuBase = ''
        ${nuConfirmHuman}
        # all git calls go through this: hooks and fsmonitor are disabled so the repos' own hooks/watchers can't run, and the deploy key is used for SSH remotes
        def --wrapped gitSafe [repo: string, ...args: string] {
            ^${bin.git} -C $repo -c core.hooksPath=/dev/null -c core.fsmonitor=false -c "core.sshCommand=${bin.ssh} -i /root/.ssh/nixos-config -o IdentitiesOnly=yes" ...$args
        }
        # manual errors print in red; quiet errors go to the journal and notify the first user
        def reportProblem [repo: string, text: string, --quiet] {
            if not $quiet {
                print -e $"(ansi red)($repo): ($text)(ansi rst)"
            } else {
                ^${bin.logger} -t nixos-config $"($repo): ($text)"
                try {
                    ^${bin."systemd-run"} --quiet --machine $"${builtins.head vars.users}@.host" --user ${bin."notify-send"} -u critical "NixOS config" $text
                } catch { }
            }
        }
        # direct subdirs of hm whose owner is none of {root, first user, expected owner} are foreign:
        # never chown/chmod them (perms) and refuse to run anything else while they exist —
        # a stray owned-by-someone dir under hm can become code root evaluates after a passwordless reconf
        def foreignHmDirs [] {
            let firstUser = "${builtins.head vars.users}"
            let users = ${hmUsersNuList}
            mut bad = []
            # cur is the host repo mounted a second time, hostRepos skips it too
            for repo in (ls ${vars.configPath} | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) != "cur" }) {
                let hm = $"($repo)/hm"
                if not ($hm | path exists) { continue }
                for dir in (^${bin.find} $hm -mindepth 1 -maxdepth 1 -type d | lines) {
                    let name = ($dir | path basename)
                    let owner = ((^${bin.stat} -c %U $dir | complete).stdout | str trim)
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
                reportProblem "cfg" $"foreign hm dir ($d): fix its owner and run cfg perms" --quiet
            }
            if ($foreign | is-not-empty) { exit 1 }
        }
    '';
    # nuBase plus what only the switching commands (update, rebuild, reconf) need.
    nuSwitch = ''
        ${nuBase}
        def commitIfChanged [prefix: string, message?: string, --no-add] {
            # status --porcelain is empty only when the worktree is clean
            let dirty = (not ((gitSafe $"${vars.configPath}/cur" status --porcelain | complete).stdout | is-empty))
            if $dirty or ($message | is-not-empty) {
                let msg = (if ($message | is-empty) { $"($prefix) (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message })
                let noAddArgs = if $no_add { [ "--no-add" ] } else { [] }
                try { ^${bin.cfg} commit $msg ...$noAddArgs } catch { }
                # a flake sees only what git tracks: with an uncommitted tree the build would silently miss new files
                if not ((gitSafe $"${vars.configPath}/cur" status --porcelain | complete).stdout | is-empty) {
                    error make { msg: "the config is not committed (see above), not switching" }
                }
            }
        }
        # root's HM must only come from root-owned, tightly permissioned hm/root dirs: root evaluates
        # these files and the switch runs without a password — a user-writable or ACL'd hm/root is a
        # passwordless path to root. If a check fails, only root's switch is skipped.
        def rootHmSafe [] {
            [ "${vars.configPath}/common/hm/root" "${vars.configPath}/${vars.host}/hm/root" ]
            | all { |d|
                if not ($d | path exists) { true } else {
                    let ownerOk = ((^${bin.find} $d -maxdepth 0 ! -user root | complete).stdout | is-empty)
                    let writeOk = ((^${bin.find} $d -maxdepth 0 -perm /022 | complete).stdout | is-empty)
                    let aclOk = ((^${bin.getfacl} -cp $d | complete).stdout | lines | where { |l| not ($l =~ '^(user|group|other|mask)::') } | is-empty)
                    $ownerOk and $writeOk and $aclOk
                }
            }
        }
        def homeSwitchAll [] {
            # runuser from root asks no password; sudo env_reset drops NH_FLAKE, hence the explicit flake path
            # --impure: see sys/iets.nix (iets reads the locked local common only in impure mode)
            if (rootHmSafe) {
                with-env { HOME: "/root" } { ^${bin.nh} home switch ${vars.configPath}/cur -c "root@${vars.host}" --impure }
            } else {
                print $"(ansi red)hm/root is not owned and permissioned for root; skipping root's home switch(ansi rst)"
            }
            for u in ${hmUsersNuList} {
                if ((^${bin.id} -u $u | complete).exit_code != 0) {
                    print $"(ansi yellow)($u): no such user yet, skipping home switch(ansi rst)"
                    continue
                }
                let uid = ((^${bin.id} -u $u | complete).stdout | str trim)
                ^${bin.runuser} -u $u -- ${bin.env} HOME=$"/home/($u)" XDG_RUNTIME_DIR=$"/run/user/($uid)" ${bin.nh} home switch ${vars.configPath}/cur -c $"($u)@${vars.host}" --impure
            }
        }
        # lstGen is the last built generation that was never booted (maybe switched into); deleting its
        # profile link is safe even when switched into: the running system stays a GC root via
        # /nix/var/nix/gcroots/current-system
        def dropLstGen [bootedGen: string, lstGen: string, newGen: string] {
            if ($lstGen == $bootedGen) or ($lstGen == $newGen) { return }
            let lstLinks = (ls /nix/var/nix/profiles
                | where { |e| $e.type == "symlink" and ($e.name | path basename | str starts-with "system-") }
                | where { |e| ((^${bin.readlink} -f $e.name | complete).stdout | str trim) == $lstGen })
            if (($lstLinks | length) == 1) {
                ^${bin."nix-env"} --profile /nix/var/nix/profiles/system --delete-generations ($lstLinks.0.name | path basename | str replace -a -r '\D' ''')

                ^${bin."switch-to-configuration"} boot
            }
        }
    '';
}