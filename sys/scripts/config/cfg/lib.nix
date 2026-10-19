{ pkgs, vars }:
''
        # all host repos in ${vars.configPath} (git repos other than common; the cur mount is not a separate repo)
        def hostRepos [] {
            ls ${vars.configPath} | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) not-in [ "common" "cur" ] }
        }
        # --host aliases: `cur` is this host's repo, `com`/`common` the common one; else a repo name under the config dir
        def hostRepo [host: string] {
            let dir = (if $host == "cur" { "${vars.host}" } else if $host in [ "com" "common" ] { "common" } else { $host })
            let repo = $"${vars.configPath}/($dir)"
            if not ($"($repo)/.git" | path exists) {
                error make { msg: $"($repo) is not a config repo" }
            }
            $repo
        }
        # repo to act on: --host wins; otherwise resolved by walking up from PWD and comparing device+inode,
        # so a bind mount (e.g. a directory bound to another host repo) resolves to the real repo; fallback is the host repo.
        # PWD inside common resolves to the host repo — common is touched alone only via --host com or --single
        def currentRepo [host?: string, --single] {
            if ($host | is-not-empty) {
                return (hostRepo $host)
            }
            let repos = ([ $"${vars.configPath}/common" ] ++ (hostRepos))
            # stat -L follows symlinks: device:inode of the dir itself
            let repoIds = $repos | each { |r| (^${pkgs.coreutils}/bin/stat -L -c '%d:%i' $r | complete | get stdout | str trim) }
            mut p = ($env.PWD | path expand)
            loop {
                let id = (^${pkgs.coreutils}/bin/stat -L -c '%d:%i' $p | complete | get stdout | str trim)
                let hits = ($repoIds | enumerate | where { |x| $x.item == $id })
                if ($hits | is-not-empty) {
                    let hit = ($repos | get $hits.0.index)
                    if $hit == $"${vars.configPath}/common" and not $single { break }
                    return $hit
                }
                let parent = ($p | path dirname)
                if $parent == $p { break }
                $p = $parent
            }
            $"${vars.configPath}/${vars.host}"
        }
        # refuses to touch a repo mid-rebase or on a detached HEAD
        def checkRepoState [repo: string] {
            let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)  # .git dir path, relative to the repo
            if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
                error make { msg: $"($repo): rebase in progress, finish it first" }
            }
            let branch = (gitSafe $repo symbolic-ref -q --short HEAD | complete)  # fails on detached HEAD
            if $branch.exit_code != 0 {
                error make { msg: $"($repo): detached HEAD" }
            }
            if ($branch.stdout | str trim) != "main" {  # only main is synced with origin
                error make { msg: $"($repo): on branch ($branch.stdout | str trim), switch to main first" }
            }
        }
        # only DNS/connectivity failures count as offline; auth and other errors are real errors
        def isNetworkError [stderr: string] {
            [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
              "No route to host" "Connection timed out" "Connection refused" ]
            | any { |pat| $stderr | str contains $pat }
        }
        # true when candidate keeps every commit of accepted, except that the tip may be amended with the same
        # tree (what cfg rename does): fast-forward, or accepted's parent is still there and the first commit
        # after it has accepted's tree
        def historyKept [repo: string, accepted: string, candidate: string] {
            if (gitSafe $repo merge-base --is-ancestor $accepted $candidate | complete | get exit_code) == 0 { return true }
            let parent = (gitSafe $repo rev-parse -q --verify $"($accepted)^" | complete)  # fails when accepted is the root commit
            let firstAfter = if $parent.exit_code == 0 {
                let parent = ($parent.stdout | str trim)
                if (gitSafe $repo merge-base --is-ancestor $parent $candidate | complete | get exit_code) != 0 { return false }
                gitSafe $repo rev-list --reverse --ancestry-path $"($parent)..($candidate)" | complete | get stdout | lines
            } else {
                gitSafe $repo rev-list --max-parents=0 $candidate | complete | get stdout | lines
            }
            if ($firstAfter | is-empty) { return false }  # the tip was deleted, not amended
            let tree = { |rev| gitSafe $repo rev-parse $"($rev)^{tree}" | complete | get stdout | str trim }
            (do $tree $firstAfter.0) == (do $tree $accepted)
        }
        # shows what a rewritten origin history drops and brings, in red, and asks; true = take it
        def confirmRewrite [repo: string, accepted: string, candidate: string] {
            print -e $"(ansi red_bold)($repo): history on origin was rewritten(ansi rst)"
            print -e $"(ansi red_bold)commits that would be lost:(ansi rst)"
            gitSafe $repo --no-pager log --oneline $"($candidate)..($accepted)"
            print -e $"(ansi red_bold)commits that would come instead:(ansi rst)"
            gitSafe $repo --no-pager log --oneline $"($accepted)..($candidate)"
            print -e $"(ansi red_bold)file changes between them:(ansi rst)"
            gitSafe $repo --no-pager diff --stat $accepted $candidate
            (input $"(ansi red_bold)take origin's history? type yes: (ansi rst)" | str trim) == "yes"
        }
        # fetches origin's main into origin/candidate and rebases local work on it (uncommitted changes ride along
        # via --autostash). origin/main is moved to the candidate only when historyKept says the history was not
        # rewritten: a captured host force-pushing a gutted repo is refused here, so this host keeps its copy and
        # keeps reporting until someone looks. origin/main is also the lease repoPush checks against, so nothing
        # is pushed on top of a refused history either. --on-rewrite { |accepted, candidate| -> bool } gets to
        # decide instead of refusing (cfg sync passes confirmRewrite); nothing automatic may pass it.
        # returns { online: bool, changed: bool }; with --pause skips the fetch if FETCH_HEAD is fresh
        def repoSync [repo: string, --pause, --on-rewrite: closure] {
            checkRepoState $repo
            let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)
            let fetchHead = $"($repo)/($gitDir)/FETCH_HEAD"
            if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < 3min) {
                return { online: true, changed: false }
            }
            # fetch fails on network errors, rebase fails on conflicts; separate calls tell the two apart
            # --refmap= stops git from also updating origin/main "opportunistically" through the configured refspec
            let fetch = (gitSafe $repo fetch --refmap= origin +refs/heads/main:refs/remotes/origin/candidate | complete)
            if $fetch.exit_code != 0 {
                if (isNetworkError $fetch.stderr) {
                    return { online: false, changed: false }
                }
                error make { msg: $"($repo): fetch failed\n($fetch.stderr)" }
            }
            let candidate = (gitSafe $repo rev-parse origin/candidate | complete | get stdout | str trim)
            let accepted = (gitSafe $repo rev-parse -q --verify origin/main | complete)  # missing before the first sync of a fresh clone
            let accepted = if $accepted.exit_code == 0 { $accepted.stdout | str trim } else { null }
            if $accepted != null and not (historyKept $repo $accepted $candidate) {
                if $on_rewrite == null or not (do $on_rewrite $accepted $candidate) {
                    error make { msg: $"($repo): history on origin was rewritten, local copy kept; compare with origin/candidate, then cfg sync to take it" }
                }
            }
            gitSafe $repo update-ref refs/remotes/origin/main $candidate
            let oldHead = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)  # hash of the current commit
            # files changed only by mtime make --autostash bail out; refresh the index stat info first (nonzero when real changes exist)
            try { gitSafe $repo update-index -q --really-refresh } catch { }
            let stashCount = (gitSafe $repo stash list | complete | get stdout | lines | length)  # baseline for the autostash check below
            # --onto: replay only what was committed here after the last accepted origin state; commits a
            # taken rewrite removed are not resurrected (plain `rebase origin/main` would replay them too)
            let rebase = if $accepted != null {
                gitSafe $repo rebase --autostash --quiet --onto origin/main $accepted | complete
            } else {
                gitSafe $repo rebase --autostash --quiet origin/main | complete
            }
            if $rebase.exit_code != 0 {
                if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
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
            let remote = (gitSafe $repo rev-parse origin/main | complete | get stdout | str trim)  # remote tip; local == remote means nothing to push
            if $local == $remote {
                return true
            }
            gitSafe $repo --no-pager log -1 --oneline '--format=%C(magenta)%h%C(auto)%d %s'
            let start = (date now)
            # --force-with-lease overwrites origin/main only if it still matches what we fetched
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
            let res = (^/run/current-system/sw/bin/nix flake update --refresh common | complete)
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
''
