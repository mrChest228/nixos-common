{ pkgs, vars }:
''
        def fetchCandidate [repo: string, branch: string] {
            let result = (gitSafe $repo fetch --refmap= origin $"+refs/heads/($branch):refs/remotes/origin/candidate" | complete)
            if $result.exit_code == 0 {
                { online: true, state: "fetched", candidate: (gitOut $repo rev-parse origin/candidate) }
            } else if (isNetworkError $result.stderr) {
                { online: false, state: "offline" }
            } else if ($result.stderr | str contains "couldn't find remote ref") {
                { online: true, state: "missing" }
            } else {
                error make { msg: $"($repo): fetch failed\n($result.stderr)" }
            }
        }
        def pushCandidate [repo: string, branch: string, source: string, accepted: string] {
            let lease = $"--force-with-lease=refs/heads/($branch):($accepted)"
            let result = (gitSafe $repo push $lease origin $"($source):refs/heads/($branch)" | complete)
            if $result.exit_code == 0 {
                { online: true, state: "pushed" }
            } else if (isNetworkError $result.stderr) {
                print ($REPORT_COLOR.redBold + $repo + ": not pushed (offline), will be pushed later" + $REPORT_COLOR.reset)
                { online: false, state: "offline" }
            } else {
                { online: true, state: "rejected", stderr: $result.stderr }
            }
        }
        def branchResult [branch: string, online: bool, state: string] {
            { online: $online, state: $state, branch: $branch }
        }
        def branchReport [sync: record, pushed: record, branch: string, localFiles: list<record>, commits: list<record>] {
            let state = if $sync.state? == "rewritten" { "rewritten" } else if $pushed.state == "offline" { "local-ahead" } else { $pushed.state }
            { online: $pushed.online, state: $state, branch: $branch, diff: $sync.diff?, localFiles: $localFiles, pushed: (if $pushed.state in [ "pushed" "offline" ] { $commits } else { [] }) }
        }
        def catastropheResult [direction: string, branch: string, diff: record, accepted: string, candidate: string, localFiles?: any] {
            let result = { online: true, state: "catastrophe", direction: $direction, branch: $branch, diff: $diff, accepted: $accepted, candidate: $candidate }
            if $localFiles == null { $result } else { $result | upsert localFiles $localFiles }
        }
        def runRepoBranches [repo: string, branches: list<string>, command: string, action: closure, --quiet] {
            mut ok = true
            mut results = []
            for branch in $branches {
                let result = (try {
                    do $action $repo $branch
                } catch { |e|
                    let target = if $command == "sync" { $"($repo)/($branch)" } else { $repo }
                    reportProblem $target ($e.msg? | default $"($e)") --quiet=$quiet
                    null
                })
                if $result == null {
                    $ok = false
                } else if not $result.online {
                    if $command == "sync" {
                        print $"($REPORT_COLOR.redBold)($repo)/($branch): offline, sync skipped($REPORT_COLOR.reset)"
                        $ok = false
                    } else if not $quiet {
                        print $"($REPORT_COLOR.redBold)($repo): offline, ($command) skipped($REPORT_COLOR.reset)"
                    }
                    break
                } else if $result.state == "catastrophe" {
                    $ok = false
                } else {
                    clearCatastropheMarker $repo $branch
                }
                if $result != null and $result.online { $results = ($results | append { branch: $branch, result: $result }) }
            }
            { ok: $ok, results: $results }
        }
        def pushHistoryState [repo: string, accepted: string, candidate: string, onRewrite: any] {
            let diff = if $accepted == "" { null } else { historyDiff $repo $accepted $candidate }
            let invalid = ($diff != null) and not $diff.kept
            let rewritten = $invalid and $onRewrite != null and (do $onRewrite $accepted $candidate)
            { diff: $diff, catastrophe: ($invalid and not $rewritten) }
        }
        def repoBranches [repo: string] {
            gitOut $repo for-each-ref '--format=%(refname:short)' refs/heads/ | lines
        }
        def updateRemoteBranchRef [repo: string, branch: string, rev: string] {
            let ref = $"refs/remotes/origin/($branch)"
            let current = (gitSafe $repo rev-parse -q --verify $ref | complete)
            if $current.exit_code == 0 {
                let old = ($current.stdout | str trim)
                if $old != $rev { gitSafe $repo update-ref $ref $rev $old }
            } else {
                gitSafe $repo update-ref $ref $rev
            }
        }
        def isNetworkError [stderr: string] {
            [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
              "No route to host" "Connection timed out" "Connection refused" ]
            | any { |pat| $stderr | str contains $pat }
        }
        def applyRepoSync [repo: string, gitDir: string, branch: string, accepted: any, candidate: string, diff: any, --rewritten] {
            gitSafe $repo update-ref $"refs/remotes/origin/($branch)" $candidate
            # files changed only by mtime make --autostash bail out; refresh the index stat info first (nonzero when real changes exist)
            try { gitSafe $repo update-index -q --really-refresh } catch { }
            let stashCount = (gitSafe $repo stash list | complete | get stdout | lines | length)  # baseline for the autostash check below
            # Replay only commits after accepted history; removed commits stay removed.
            let rebase = if $accepted != null {
                gitSafe $repo rebase --autostash --quiet --onto $candidate $accepted | complete
            } else {
                gitSafe $repo rebase --autostash --quiet $candidate | complete
            }
            if $rebase.exit_code != 0 {
                if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) { gitSafe $repo rebase --abort }
                error make { msg: $"($repo): rebase failed\n($rebase.stderr)" }
            }
            # --autostash keeps the stash entry (and drops the changes from the worktree) when it can't re-apply cleanly
            if ((gitSafe $repo stash list | complete | get stdout | lines | length) > $stashCount) or ($rebase.stderr | str contains "safe in the stash") { error make { msg: $"($repo): local changes were kept in the stash, apply it manually" } }
            { online: true, state: (if $rewritten { "rewritten" } else { "updated" }), branch: $branch, diff: $diff, candidate: $candidate }
        }
        # Fetch the candidate and return rewrites for the caller to handle.
        def repoSync [repo: string, --pause] {
            let gitDir = (checkRepoState $repo)
            let branch = (repoBranch $repo)
            let fetchHead = $"($repo)/($gitDir)/FETCH_HEAD"
            if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < 3min) { return { online: true } }
            # --refmap keeps the fetched candidate separate from configured origin refspecs.
            let fetch = (fetchCandidate $repo $branch)
            if not $fetch.online { return { online: false, state: "offline" } }
            if $fetch.state == "missing" {  # branch made here, not on origin yet; repoPush creates it
                return { online: true, state: "origin-missing" }
            }
            let candidate = $fetch.candidate
            let acceptedResult = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete)
            let accepted = if $acceptedResult.exit_code == 0 { $acceptedResult.stdout | str trim } else { null }
            let diff = if $accepted == null { null } else { historyDiff $repo $accepted $candidate }
            if $accepted != null and not $diff.kept { return ((catastropheResult "remote" $branch $diff $accepted $candidate (worktreeFiles $repo)) | upsert gitDir $gitDir) }
            applyRepoSync $repo $gitDir $branch $accepted $candidate $diff
        }
        # Push with a lease; sync and retry once after a rejection.
        def repoPush [repo: string, --no-retry, --report, --on-rewrite: closure] {
            let branch = (repoBranch $repo)
            let local = (gitOut $repo rev-parse HEAD)
            let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")  # remote tip (empty for a branch origin lacks); local == remote means nothing to push
            if $local == $remote { return (if $report { (branchResult $branch true "up-to-date") } else { true }) }
            let pushState = (pushHistoryState $repo $remote $local $on_rewrite)
            let diff = $pushState.diff
            if $pushState.catastrophe {
                if $report { return (catastropheResult "local" $branch $diff $remote $local (worktreeFiles $repo)) }
                error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
            }
            if not $report { gitSafe $repo --no-pager log -1 --oneline '--format=%C(magenta)%h%C(auto)%d %s' }
            let start = (date now)
            mut pushed = (pushCandidate $repo $branch "HEAD" $remote)
            if $pushed.state == "offline" { return (if $report { (branchResult $branch false "offline") } else { false }) }
            if $pushed.state == "rejected" {
                if $no_retry { error make { msg: $"($repo): push rejected\n($pushed.stderr)" } }
                # remote moved between our fetch and push: sync again and retry once
                let fetched = (repoSync $repo)
                let sync = if $fetched.state? == "catastrophe" and $on_rewrite != null and (do $on_rewrite $fetched.accepted $fetched.candidate) {
                    applyRepoSync $repo $fetched.gitDir $branch $fetched.accepted $fetched.candidate $fetched.diff --rewritten
                } else {
                    $fetched
                }
                if $sync.state? == "catastrophe" {
                    if $report { return $sync }
                    error make { msg: $"($repo): history on origin was rewritten, local copy kept" }
                }
                let local = (gitOut $repo rev-parse HEAD)
                let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")
                let pushState = (pushHistoryState $repo $remote $local $on_rewrite)
                let diff = $pushState.diff
                if $pushState.catastrophe {
                    if $report { return (catastropheResult "local" $branch $diff $remote $local (worktreeFiles $repo)) }
                    error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
                }
                $pushed = (pushCandidate $repo $branch "HEAD" $remote)
                if $pushed.state == "offline" { return (if $report { (branchResult $branch false "offline") } else { false }) }
                if $pushed.state == "rejected" { error make { msg: $"($repo): push failed\n($pushed.stderr)" } }
            }
            if not $report { print $"($REPORT_COLOR.greenBold)Successful push in ((date now) - $start)($REPORT_COLOR.reset)" }
            if $report { { online: true, state: "pushed", branch: $branch } } else { true }
        }
        # syncs one local branch without checking it out
        def repoSyncBranch [repo: string, branch: string, action: string, --on-rewrite: closure, --on-local-rewrite: closure] {
            checkRepoState $repo
            let local = (gitOut $repo rev-parse $"refs/heads/($branch)")
            let acceptedResult = (gitSafe $repo rev-parse -q --verify $"refs/remotes/origin/($branch)" | complete)
            let accepted = if $acceptedResult.exit_code == 0 { $acceptedResult.stdout | str trim } else { null }
            let fetch = (fetchCandidate $repo $branch)
            if not $fetch.online { return (branchResult $branch false "offline") }
            if $fetch.state == "missing" {
                    if $action == "pull" { return { online: true, state: "origin-missing", branch: $branch } }
                    let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" "")
                    if $pushed.state == "offline" { return (branchResult $branch false "offline") }
                    if $pushed.state != "pushed" { error make { msg: $"($repo): push of new branch ($branch) failed\n($pushed.stderr)" } }
                    updateRemoteBranchRef $repo $branch $local
                    return { online: true, state: "pushed", branch: $branch, pushed: (commitsToPush $repo "" $local) }
                }
            let candidate = $fetch.candidate
            let base = if $accepted == null { $candidate } else { $accepted }
            if $local == $base {
                let diff = (historyDiff $repo $base $candidate)
                mut rewriteAccepted = false
                if not $diff.kept {
                    if $on_rewrite == null or not (do $on_rewrite $base $candidate) { return (catastropheResult "remote" $branch $diff $base $candidate) }
                    $rewriteAccepted = true
                }
                if $local != $candidate { gitSafe $repo update-ref $"refs/heads/($branch)" $candidate $local }
                updateRemoteBranchRef $repo $branch $candidate
                return { online: true, state: (if $rewriteAccepted { "rewritten" } else if $local == $candidate { "up-to-date" } else { "updated" }), branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
            }
            if $candidate == $base {
                let diff = (historyDiff $repo $base $local)
                if not $diff.kept {
                    if $action == "sync" and $on_local_rewrite != null and (do $on_local_rewrite $base $local) {
                        let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $base)
                        if $pushed.state == "offline" { return (branchResult $branch false "offline") }
                        if $pushed.state != "pushed" { error make { msg: $"($repo): push of rewritten branch ($branch) failed\n($pushed.stderr)" } }
                        updateRemoteBranchRef $repo $branch $local
                        return { online: true, state: "pushed", branch: $branch, diff: $diff, accepted: $base, candidate: $local, pushed: (commitsToPush $repo $base $local) }
                    }
                    return { online: true, state: "catastrophe", direction: "local", branch: $branch, diff: $diff, accepted: $base, candidate: $local }
                }
                if $action == "pull" {
                    if $accepted == null { updateRemoteBranchRef $repo $branch $candidate }
                    return { online: true, state: "local-ahead", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
                }
                let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $base)
                if $pushed.state == "offline" { return (branchResult $branch false "offline") }
                if $pushed.state != "pushed" { error make { msg: $"($repo): push of branch ($branch) failed\n($pushed.stderr)" } }
                updateRemoteBranchRef $repo $branch $local
                return { online: true, state: "pushed", branch: $branch, diff: null, accepted: $base, candidate: $local, pushed: (commitsToPush $repo $base $local) }
            }
            let remoteDiff = (historyDiff $repo $base $candidate)
            let localDiff = (historyDiff $repo $base $local)
            if not $remoteDiff.kept { if $on_rewrite == null or not (do $on_rewrite $base $candidate) { return (catastropheResult "remote" $branch $remoteDiff $base $candidate) } }
            if not $localDiff.kept { return (catastropheResult "local" $branch $localDiff $base $local) }
            let replay = (gitSafe $repo replay --onto $candidate $"($base)..refs/heads/($branch)" --ref-action=print | complete)
            if $replay.exit_code != 0 {
                let merge = (gitSafe $repo merge-tree --write-tree --name-only --no-messages $candidate $local | complete)
                let conflicts = if $merge.exit_code == 1 { $merge.stdout | lines | skip 1 } else { [] }
                return { online: true, state: "conflict", branch: $branch, conflictFiles: $conflicts }
            }
            if not ($replay.stdout | str trim | is-empty) { $replay.stdout | gitSafe $repo update-ref --stdin }
            updateRemoteBranchRef $repo $branch $candidate
            let replayed = (gitOut $repo rev-parse $"refs/heads/($branch)")
            if $action in [ "push" "sync" ] and $replayed != $candidate {
                let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $candidate)
                if $pushed.state == "offline" { return { online: false, state: "offline", branch: $branch, diff: $remoteDiff, pushed: (commitsToPush $repo $candidate $replayed) } }
                if $pushed.state != "pushed" { error make { msg: $"($repo): push of replayed branch ($branch) failed\n($pushed.stderr)" } }
                updateRemoteBranchRef $repo $branch $replayed
                return { online: true, state: "pushed", branch: $branch, diff: $remoteDiff, accepted: $base, candidate: $replayed, pushed: (commitsToPush $repo $candidate $replayed) }
            }
            { online: true, state: "updated", branch: $branch, diff: $remoteDiff, accepted: $base, candidate: $candidate }
        }
        # revision of the common input recorded in the repo's flake.lock (null if absent)
''
