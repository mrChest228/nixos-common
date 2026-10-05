export def returnCode [code: int] {
    run-external "nu" "-c" $"exit ($code)"
}
export def --env silent [action: closure] {
    let src = (view source $action)
    returnCode (
        try {
            let res = (do $action | complete)
            if $res.exit_code != 0 {
               print $"($res.stdout)\n(ansi red)($res.stderr)\n(ansi red_bold)Command ($src) FAILED \(exit code ($res.exit_code)\)(ansi rst)"
            }
            $res.exit_code
        } catch { |e|
            print ($e.rendered? | default $e)
            1
        }
    )
}

# All git calls go through this: hooks and fsmonitor are disabled so the repos' own hooks/watchers can't run, and the deploy key is used for SSH remotes.
export def --wrapped gitSafe [repo: string, ...args: string] {
    ^git -C $repo -c core.hooksPath=/dev/null -c core.fsmonitor=false -c $"core.sshCommand=($SSH_COMMAND)" ...$args
}

# "common" -> $CONFIG_PATH/common, anything else is treated as a hostname -> $CONFIG_PATH/<host>
export def repoPath [host: string] {
    if $host == "common" { $"($CONFIG_PATH)/common" } else { $"($CONFIG_PATH)/($host)" }
}

# All host repos in $CONFIG_PATH (git repos other than common; the cur mount is not a separate repo)
export def hostRepos [] {
    ls -D $"($CONFIG_PATH)/*" | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) not-in [ "common" "cur" ] }
}

# Repo to act on: --host wins; otherwise resolved from the current directory.
# cur and /home/<user>/cfg both resolve to this host's repo; outside a git dir defaults to the host repo too.
export def currentRepo [host?: string] {
    if ($host | is-not-empty) {
        return (repoPath $host)
    }
    let top = (try { ^git rev-parse --show-toplevel | complete | get stdout | str trim } catch { "" })
    if ($top | is-empty) {
        return (repoPath $HOST)
    }
    if ($top | str starts-with $"($CONFIG_PATH)/") {
        if ($top | path basename) == "cur" { return (repoPath $HOST) }
        return $top
    }
    if ($top | path basename) == "cfg" and ($top | path dirname | path dirname) == "/home" {
        return (repoPath $HOST)
    }
    error make { msg: $"($top) is not a config repo" }
}

# Refuses to touch a repo mid-rebase or on a detached HEAD.
export def checkRepoState [repo: string] {
    let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)
    if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
        error make { msg: $"($repo): rebase in progress, finish it first" }
    }
    if (gitSafe $repo symbolic-ref -q HEAD | complete | get exit_code) != 0 {
        error make { msg: $"($repo): detached HEAD" }
    }
}

# Only DNS/connectivity failures count as offline; auth and other errors are real errors.
export def isNetworkError [stderr: string] {
    [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
      "No route to host" "Connection timed out" "Connection refused" ]
    | any { |pat| $stderr | str contains $pat }
}

# Fetches origin/main and rebases local work on it (uncommitted changes ride along via --autostash).
# Returns { online: bool, changed: bool }; with --pause skips the fetch if FETCH_HEAD is fresh.
export def repoSync [repo: string, --pause] {
    checkRepoState $repo
    let fetchHead = $"($repo)/.git/FETCH_HEAD"
    if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < $PULL_PAUSE) {
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

# Pushes HEAD to origin/main with --force-with-lease. On rejection syncs once and retries.
# Returns false when the remote can't be reached (commit stays local).
export def repoPush [repo: string, --no-retry] {
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

# Revision of the common input recorded in the repo's flake.lock (null if absent)
export def lockedRev [repo: string] {
    try {
        open $"($repo)/flake.lock" | from json | get nodes.common.locked.rev
    } catch {
        null
    }
}

# Re-locks the common input inside a host flake; nix output is shown only on failure
export def updateCommonLock [repo: string] {
    cd $repo
    let res = (^nix flake update --refresh common | complete)
    if $res.exit_code != 0 {
        print $"($res.stdout)\n(ansi red)($res.stderr)(ansi rst)"
        error make { msg: $"($repo): nix flake update common failed" }
    }
}

# Commits everything in the repo with the owner's colored change list. Returns true when a commit was made.
export def commitRepo [repo: string, message: string] {
    cd $repo
    gitSafe $repo add .
    if not ((gitSafe $repo status -s | complete | get stdout) | is-empty) {
        echo "File changes:"

        # Changes with time printing
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

# Commit message format: "<HOST>: <message>" (or "Commit <date>" when no message is given)
export def buildMessage [message?: string] {
    $"($HOST): " + if ($message | is-empty) { $"Commit (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }
}

# Always prints the error in red; in --quiet (service) mode also logs to the journal and notifies the first user.
export def reportProblem [repo: string, text: string, --quiet] {
    print -e $"(ansi red)($repo): ($text)(ansi rst)"
    if $quiet {
        ^logger -t nixos-config $"($repo): ($text)"
        try {
            ^systemd-run --quiet --machine=$"($FIRST_USER)@.host" --user $NOTIFY_SEND -u critical "NixOS config" $text
        } catch { }
    }
}

# Git runs here as root, so pulled/created files are root-owned; re-apply the tmpfiles Z-rules to fix ownership under $CONFIG_PATH
export def fixPermissions [] {
    ^systemd-tmpfiles --create --prefix $CONFIG_PATH
}
