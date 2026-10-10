{ config, lib, com, pkgs, vars, self, ... }: {
    conf.lib = ''
        # all git calls go through this: hooks and fsmonitor are disabled so the repos' own hooks/watchers can't run, and the deploy key is used for SSH remotes
        def --wrapped gitSafe [repo: string, ...args: string] {
            ^git -C $repo -c core.hooksPath=/dev/null -c core.fsmonitor=false -c "core.sshCommand=ssh -i /root/.ssh/nixos-config -o IdentitiesOnly=yes" ...$args
        }
        # all host repos in ${vars.configPath} (git repos other than common; the cur mount is not a separate repo)
        def hostRepos [] {
            ls -D "${vars.configPath}/*" | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) not-in [ "common" "cur" ] }
        }
        # repo to act on: --host wins; otherwise resolved from the current directory
        # cur and /home/<user>/cfg both resolve to this host's repo; outside a git dir defaults to the host repo too
        def currentRepo [host?: string] {
            if ($host | is-not-empty) {
                return $"${vars.configPath}/($host)"
            }
            let top = (try { ^git rev-parse --show-toplevel | complete | get stdout | str trim } catch { "" })
            if ($top | is-empty) {
                return "${vars.configPath}/${vars.host}"
            }
            if ($top | str starts-with "${vars.configPath}/") {
                if ($top | path basename) == "cur" { return "${vars.configPath}/${vars.host}" }
                return $top
            }
            if ($top | path basename) == "cfg" and ($top | path dirname | path dirname) == "/home" {
                return "${vars.configPath}/${vars.host}"
            }
            error make { msg: $"($top) is not a config repo" }
        }
        # refuses to touch a repo mid-rebase or on a detached HEAD
        def checkRepoState [repo: string] {
            let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)
            if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
                error make { msg: $"($repo): rebase in progress, finish it first" }
            }
            if (gitSafe $repo symbolic-ref -q HEAD | complete | get exit_code) != 0 {
                error make { msg: $"($repo): detached HEAD" }
            }
        }
        # only DNS/connectivity failures count as offline; auth and other errors are real errors
        def isNetworkError [stderr: string] {
            [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
              "No route to host" "Connection timed out" "Connection refused" ]
            | any { |pat| $stderr | str contains $pat }
        }
        # fetches origin/main and rebases local work on it (uncommitted changes ride along via --autostash)
        # returns { online: bool, changed: bool }; with --pause skips the fetch if FETCH_HEAD is fresh
        def repoSync [repo: string, --pause] {
            checkRepoState $repo
            let fetchHead = $"($repo)/.git/FETCH_HEAD"
            if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < 3min) {
                return { online: true, changed: false }
            }
            # fetch fails on network errors, rebase fails on conflicts; separate calls tell the two apart
            let fetch = (gitSafe $repo fetch origin main | complete)
            if $fetch.exit_code != 0 {
                if (isNetworkError $fetch.stderr) {
                    return { online: false, changed: false }
                }
                error make { msg: $"($repo): fetch failed\n($fetch.stderr)" }
            }
            let oldHead = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            # files changed only by mtime make --autostash bail out; refresh the index stat info first (nonzero when real changes exist)
            try { gitSafe $repo update-index -q --really-refresh } catch { }
            let stashCount = (gitSafe $repo stash list | complete | get stdout | lines | length)
            let rebase = (gitSafe $repo rebase --autostash --quiet origin/main | complete)
            if $rebase.exit_code != 0 {
                if ($"($repo)/.git/rebase-merge" | path exists) or ($"($repo)/.git/rebase-apply" | path exists) {
                    gitSafe $repo rebase --abort
                }
                error make { msg: $"($repo): rebase failed\n($rebase.stderr)" }
            }
            # --autostash keeps the stash entry (and drops the changes from the worktree) when it can't re-apply cleanly
            if ((gitSafe $repo stash list | complete | get stdout | lines | length) > $stashCount) or ($rebase.stderr | str contains "safe in the stash") {
                error make { msg: $"($repo): local changes were kept in the stash, apply it manually" }
            }
            { online: true, changed: ((gitSafe $repo rev-parse HEAD | complete | get stdout | str trim) != $oldHead) }
        }
        # pushes HEAD to origin/main with --force-with-lease; on rejection syncs once and retries
        # returns false when the remote can't be reached (commit stays local)
        def repoPush [repo: string, --no-retry] {
            let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            let remote = (gitSafe $repo rev-parse origin/main | complete | get stdout | str trim)
            if $local == $remote {
                return true
            }
            gitSafe $repo --no-pager log -1 --oneline '--format=%C(magenta)%h%C(auto)%d %s'
            let start = (date now)
            mut res = (gitSafe $repo push --force-with-lease origin HEAD:main | complete)
            if $res.exit_code != 0 {
                if (isNetworkError $res.stderr) {
                    # offline: keep the commit local, the timer or a later push sends it
                    print ((ansi yellow) + $repo + ": not pushed (offline), will be pushed later" + (ansi rst))
                    return false
                }
                if $no_retry {
                    error make { msg: $"($repo): push rejected\n($res.stderr)" }
                }
                # remote moved between our fetch and push: sync again and retry once
                repoSync $repo
                $res = (gitSafe $repo push --force-with-lease origin HEAD:main | complete)
                if $res.exit_code != 0 {
                    if (isNetworkError $res.stderr) {
                        print ((ansi yellow) + $repo + ": not pushed (offline), will be pushed later" + (ansi rst))
                        return false
                    }
                    error make { msg: $"($repo): push failed\n($res.stderr)" }
                }
            }
            print $"(ansi green_bold)Successful push in ((date now) - $start)(ansi rst)"
            true
        }
        # revision of the common input recorded in the repo's flake.lock (null if absent)
        def lockedRev [repo: string] {
            try {
                open $"($repo)/flake.lock" | from json | get nodes.common.locked.rev
            } catch {
                null
            }
        }
        # re-locks the common input inside a host flake; nix output is shown only on failure
        def updateCommonLock [repo: string] {
            cd $repo
            let res = (^nix flake update --refresh common | complete)
            if $res.exit_code != 0 {
                print $"($res.stdout)\n(ansi red)($res.stderr)(ansi rst)"
                error make { msg: $"($repo): nix flake update common failed" }
            }
        }
        # commits everything in the repo with the owner's colored change list; returns true when a commit was made
        def commitRepo [repo: string, message: string] {
            cd $repo
            gitSafe $repo add .
            if not ((gitSafe $repo status -s | complete | get stdout) | is-empty) {
                echo "File changes:"

                # changes with time printing
                let colors = [
                    { code: "?", color: (ansi dark_gray) }
                    { code: "!", color: (ansi dark_gray) }
                    { code: "A", color: (ansi green) }
                    { code: "M", color: (ansi yellow) }
                    { code: "D", color: (ansi red) }
                    { code: "R", color: (ansi cyan) }
                    { code: "C", color: (ansi magenta) }
                    { code: "T", color: (ansi blue) }
                    { code: "U", color: (ansi red) }
                ]
                let changesGit = (gitSafe $repo status --porcelain=v1 -z | complete | get stdout | split row (char nul) | drop)
                mut changes = []
                mut i = 0
                loop {
                    if $i >= ($changesGit | length) {
                        break
                    }
                    let line = ($changesGit | get $i)
                    let x = ($line | str substring 0..0)
                    let color = ($colors | where code == $x | if ($in | length) != 1 { ansi red } else { $in | first | get color })
                    mut pths = [($line | str substring 3..)]
                    if ($x == "R" or $x == "C") {
                        $i = $i + 1
                        $pths = ($pths | append ($changesGit | get $i))
                    }
                    let pth = ($pths | get 0)
                    let time = if ($pth | path exists) { ls -D $pth | get 0 | get modified | format date '%Y-%m-%d %H:%M:%S' } else { "?" }

                    if ($pths | get 0 | str contains " ") {
                        $pths = ($pths | upsert 0 { |pth| $"\"($pth)\"" })
                    }
                    if (($pths | length) == 2 and ($pths | get 1 | str contains " ")) {
                        $pths = ($pths | upsert 1 { |pth| $"\"($pth)\"" })
                    }

                    let pthTo = if ($pths | length) == 2 { $" -> ($pths | get 0)" } else { "" }
                    print $"($color)($x)  ($pths | last)($pthTo)(ansi rst) ($time)"
                    $i = $i + 1
                }
                silent { gitSafe $repo commit -m $message }
                true
            } else {
                print $"(ansi cyan)Nothing to commit(ansi rst)"
                false
            }
        }
        # commit message format: "<HOST>: <message>" (or "Commit <date>" when no message is given)
        def buildMessage [message?: string] {
            $"${vars.host}: " + if ($message | is-empty) { $"Commit (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }
        }
        # git runs here as root, so pulled/created files are root-owned; re-apply the tmpfiles Z-rules to fix ownership under ${vars.configPath}
        def fixPermissions [] {
            ^systemd-tmpfiles --create --prefix ${vars.configPath}
        }
        # always prints the error in red; in --quiet (service) mode also logs to the journal and notifies the first user
        def reportProblem [repo: string, text: string, --quiet] {
            print -e $"(ansi red)($repo): ($text)(ansi rst)"
            if $quiet {
                ^logger -t nixos-config $"($repo): ($text)"
                try {
                    ^systemd-run --quiet --machine=$"${builtins.head vars.users}@.host" --user ${pkgs.libnotify}/bin/notify-send -u critical "NixOS config" $text
                } catch { }
            }
        }
    '';
}
