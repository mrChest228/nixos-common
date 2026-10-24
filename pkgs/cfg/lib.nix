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
            if (gitSafe $repo symbolic-ref -q HEAD | complete | get exit_code) != 0 {  # fails on detached HEAD
                error make { msg: $"($repo): detached HEAD" }
            }
        }
        # name of the checked-out branch; every repo is synced with the same-named branch on origin
        def repoBranch [repo: string] {
            gitSafe $repo symbolic-ref -q --short HEAD | complete | get stdout | str trim
        }
        def repoBranches [repo: string] {
            gitSafe $repo for-each-ref '--format=%(refname:short)' refs/heads/ | complete | get stdout | lines
        }
        def updateRemoteBranchRef [repo: string, branch: string, rev: string] {
            let ref = $"refs/remotes/origin/($branch)"
            let current = (gitSafe $repo rev-parse -q --verify $ref | complete)
            if $current.exit_code == 0 {
                let old = ($current.stdout | str trim)
                if $old != $rev {
                    gitSafe $repo update-ref $ref $rev $old
                }
            } else {
                gitSafe $repo update-ref $ref $rev
            }
        }
        # only DNS/connectivity failures count as offline; auth and other errors are real errors
        def isNetworkError [stderr: string] {
            [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
              "No route to host" "Connection timed out" "Connection refused" ]
            | any { |pat| $stderr | str contains $pat }
        }
        def historyCommits [repo: string, hashes: list<string>] {
            $hashes | each { |hash|
                {
                    hash: $hash
                    subject: (gitSafe $repo log -1 --format=%s $hash | complete | get stdout | str trim)
                }
            }
        }
        # checks first-parent trees, allowing message-only renames but no deleted or changed commits
        def historyDiff [repo: string, accepted: string, candidate: string] {
            if (gitSafe $repo merge-base --is-ancestor $accepted $candidate | complete | get exit_code) == 0 {
                let hashes = (gitSafe $repo rev-list --reverse --first-parent $"($accepted)..($candidate)" | complete | get stdout | lines)
                return {
                    kept: true
                    renamed: []
                    deleted: []
                    added: (historyCommits $repo $hashes)
                }
            }

            let mergeBase = (gitSafe $repo merge-base $accepted $candidate | complete)
            let base = if $mergeBase.exit_code == 0 { $mergeBase.stdout | str trim } else { null }
            let aRange = if $base == null { $accepted } else { $"($base)..($accepted)" }
            let bRange = if $base == null { $candidate } else { $"($base)..($candidate)" }
            let aHashes = (gitSafe $repo rev-list --reverse --first-parent $aRange | complete | get stdout | lines)
            let bHashes = (gitSafe $repo rev-list --reverse --first-parent $bRange | complete | get stdout | lines)
            let aMerges = (gitSafe $repo rev-list --merges --first-parent $aRange | complete | get stdout | lines)
            let bMerges = (gitSafe $repo rev-list --merges --first-parent $bRange | complete | get stdout | lines)
            let aMergeIndexes = ($aHashes | enumerate | where { |entry| $entry.item in $aMerges } | get index)
            let bMergeIndexes = ($bHashes | enumerate | where { |entry| $entry.item in $bMerges } | get index)
            let aMergeIndex = if ($aMergeIndexes | is-empty) { null } else { $aMergeIndexes | first }
            let bMergeIndex = if ($bMergeIndexes | is-empty) { null } else { $bMergeIndexes | first }
            let pairedCount = ([$aHashes $bHashes] | each { |hashes| $hashes | length } | math min)
            let tree = { |hash| gitSafe $repo rev-parse $"($hash)^{tree}" | complete | get stdout | str trim }
            let subject = { |hash| gitSafe $repo log -1 --format=%s $hash | complete | get stdout | str trim }
            mut mismatch = -1
            mut renamedPairs = []
            for entry in ($aHashes | enumerate | take $pairedCount) {
                let oldHash = $entry.item
                let newHash = ($bHashes | get $entry.index)
                if (do $tree $oldHash) != (do $tree $newHash) {
                    $mismatch = $entry.index
                    break
                }
                let oldSubject = (do $subject $oldHash)
                let newSubject = (do $subject $newHash)
                if $oldSubject != $newSubject {
                    $renamedPairs = ($renamedPairs | append {
                        index: $entry.index
                        old: $oldSubject
                        new: $newSubject
                    })
                }
            }
            if $mismatch < 0 and ($bHashes | length) < ($aHashes | length) {
                $mismatch = $pairedCount
            }
            for mergeIndex in [$aMergeIndex $bMergeIndex] {
                if $mergeIndex != null and ($mismatch < 0 or $mergeIndex < $mismatch) {
                    $mismatch = $mergeIndex
                }
            }
            let hasMerges = ($aMerges | is-not-empty) or ($bMerges | is-not-empty)
            let kept = $mismatch < 0 and not $hasMerges
            let renamed = $renamedPairs
                | where { |pair| $mismatch < 0 or $pair.index < $mismatch }
                | each { |pair| { old: $pair.old, new: $pair.new } }
            let start = if $mismatch < 0 { 0 } else { $mismatch }
            let deleted = if $kept { [] } else { historyCommits $repo ($aHashes | skip $start) }
            let added = if $kept {
                historyCommits $repo ($bHashes | skip ($aHashes | length))
            } else {
                historyCommits $repo ($bHashes | skip $start)
            }
            {
                kept: $kept
                renamed: $renamed
                deleted: $deleted
                added: $added
            }
        }
        # shows what a rewritten origin history drops and brings (git's own colours, only the headline is red) and asks; true = take it
        def confirmRewrite [repo: string, accepted: string, candidate: string] {
            print -e $"(ansi red_bold)($repo): history on origin was rewritten(ansi rst)"
            print "commits that would be lost:"
            gitSafe $repo --no-pager log --oneline $"($candidate)..($accepted)"
            print "commits that would come instead:"
            gitSafe $repo --no-pager log --oneline $"($accepted)..($candidate)"
            print "file changes between them:"
            gitSafe $repo --no-pager diff --stat $accepted $candidate
            (input "take origin's history? type yes: " | str trim) == "yes"
        }
        # fetches origin's <branch> (the one checked out here) into origin/candidate and rebases local work on it
        # (uncommitted changes ride along via --autostash). origin/<branch> is moved to the candidate only when
        # historyKept says the history was not rewritten: a captured host force-pushing a gutted repo is refused
        # here, so this host keeps its copy and keeps reporting until someone looks. origin/<branch> is also the
        # lease repoPush checks against, so nothing is pushed on top of a refused history either. --on-rewrite { |accepted, candidate| -> bool } gets to
        # decide instead of refusing (cfg sync passes confirmRewrite); nothing automatic may pass it.
        # returns { online: bool, changed: bool }; with --pause skips the fetch if FETCH_HEAD is fresh
        def repoSync [repo: string, --pause, --on-rewrite: closure] {
            checkRepoState $repo
            let branch = (repoBranch $repo)
            let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)
            let fetchHead = $"($repo)/($gitDir)/FETCH_HEAD"
            if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < 3min) {
                return { online: true, changed: false }
            }
            # fetch fails on network errors, rebase fails on conflicts; separate calls tell the two apart
            # --refmap= stops git from also updating origin/<branch> "opportunistically" through the configured refspec
            let fetch = (gitSafe $repo fetch --refmap= origin $"+refs/heads/($branch):refs/remotes/origin/candidate" | complete)
            if $fetch.exit_code != 0 {
                if (isNetworkError $fetch.stderr) {
                    return { online: false, changed: false }
                }
                if ($fetch.stderr | str contains "couldn't find remote ref") {  # branch made here, not on origin yet; repoPush creates it
                    return { online: true, changed: false }
                }
                error make { msg: $"($repo): fetch failed\n($fetch.stderr)" }
            }
            let candidate = (gitSafe $repo rev-parse origin/candidate | complete | get stdout | str trim)
            let accepted = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete)  # missing before the first sync of a fresh clone or a new branch
            let accepted = if $accepted.exit_code == 0 { $accepted.stdout | str trim } else { null }
            let diff = if $accepted == null { null } else { historyDiff $repo $accepted $candidate }
            if $accepted != null and not $diff.kept {
                if $on_rewrite == null or not (do $on_rewrite $accepted $candidate) {
                    error make { msg: $"($repo): history on origin was rewritten, local copy kept; compare with origin/candidate, then cfg sync to take it" }
                }
            }
            if $diff != null {
                for rename in $diff.renamed {
                    print $"(ansi red)origin renamed: ($rename.old) -> ($rename.new)(ansi rst)"
                }
            }
            gitSafe $repo update-ref $"refs/remotes/origin/($branch)" $candidate
            let oldHead = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)  # hash of the current commit
            # files changed only by mtime make --autostash bail out; refresh the index stat info first (nonzero when real changes exist)
            try { gitSafe $repo update-index -q --really-refresh } catch { }
            let stashCount = (gitSafe $repo stash list | complete | get stdout | lines | length)  # baseline for the autostash check below
            # --onto: replay only what was committed here after the last accepted origin state; commits a
            # taken rewrite removed are not resurrected (plain `rebase origin/<branch>` would replay them too)
            let rebase = if $accepted != null {
                gitSafe $repo rebase --autostash --quiet --onto $candidate $accepted | complete
            } else {
                gitSafe $repo rebase --autostash --quiet $candidate | complete
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
        # pushes HEAD to origin/<branch> with --force-with-lease; on rejection syncs once and retries
        # returns false when the remote can't be reached (commit stays local)
        def repoPush [repo: string, --no-retry] {
            let branch = (repoBranch $repo)
            let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)  # remote tip (empty for a branch origin lacks); local == remote means nothing to push
            if $local == $remote {
                return true
            }
            if $remote != "" and not (historyDiff $repo $remote $local).kept {
                error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
            }
            gitSafe $repo --no-pager log -1 --oneline '--format=%C(magenta)%h%C(auto)%d %s'
            let start = (date now)
            # --force-with-lease overwrites origin/<branch> only if it still matches what we fetched
            mut res = (gitSafe $repo push --force-with-lease origin $"HEAD:($branch)" | complete)
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
                let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
                let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
                if $remote != "" and not (historyDiff $repo $remote $local).kept {
                    error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
                }
                $res = (gitSafe $repo push --force-with-lease origin $"HEAD:($branch)" | complete)
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
        # syncs one local branch without checking it out
        def repoSyncBranch [repo: string, branch: string, action: string, --on-rewrite: closure] {
            checkRepoState $repo
            let local = (gitSafe $repo rev-parse $"refs/heads/($branch)" | complete | get stdout | str trim)
            let acceptedResult = (gitSafe $repo rev-parse -q --verify $"refs/remotes/origin/($branch)" | complete)
            let accepted = if $acceptedResult.exit_code == 0 { $acceptedResult.stdout | str trim } else { null }
            let fetch = (gitSafe $repo fetch --refmap= origin $"+refs/heads/($branch):refs/remotes/origin/candidate" | complete)
            if $fetch.exit_code != 0 {
                if (isNetworkError $fetch.stderr) {
                    return { online: false, state: "offline", branch: $branch }
                }
                if ($fetch.stderr | str contains "couldn't find remote ref") {
                    if $action == "pull" {
                        return { online: true, state: "origin-missing", branch: $branch }
                    }
                    let lease = $"--force-with-lease=refs/heads/($branch):"
                    let pushed = (gitSafe $repo push $lease origin $"refs/heads/($branch):refs/heads/($branch)" | complete)
                    if $pushed.exit_code != 0 {
                        if (isNetworkError $pushed.stderr) {
                            return { online: false, state: "offline", branch: $branch }
                        }
                        error make { msg: $"($repo): push of new branch ($branch) failed\n($pushed.stderr)" }
                    }
                    updateRemoteBranchRef $repo $branch $local
                    return { online: true, state: "pushed", branch: $branch, pushed: [] }
                }
                error make { msg: $"($repo): fetch of branch ($branch) failed\n($fetch.stderr)" }
            }
            let candidate = (gitSafe $repo rev-parse origin/candidate | complete | get stdout | str trim)
            let base = if $accepted == null { $candidate } else { $accepted }
            if $local == $base {
                let diff = (historyDiff $repo $base $candidate)
                if not $diff.kept {
                    if $on_rewrite == null or not (do $on_rewrite $base $candidate) {
                        return { online: true, state: "catastrophe", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
                    }
                }
                if $local != $candidate {
                    gitSafe $repo update-ref $"refs/heads/($branch)" $candidate $local
                }
                updateRemoteBranchRef $repo $branch $candidate
                return { online: true, state: (if $local == $candidate { "up-to-date" } else { "updated" }), branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
            }
            if $candidate == $base {
                let diff = (historyDiff $repo $base $local)
                if not $diff.kept {
                    return { online: true, state: "catastrophe", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
                }
                if $action == "pull" {
                    if $accepted == null { updateRemoteBranchRef $repo $branch $candidate }
                    return { online: true, state: "local-ahead", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate }
                }
                let lease = $"--force-with-lease=refs/heads/($branch):($base)"
                let pushed = (gitSafe $repo push $lease origin $"refs/heads/($branch):refs/heads/($branch)" | complete)
                if $pushed.exit_code != 0 {
                    if (isNetworkError $pushed.stderr) {
                        return { online: false, state: "offline", branch: $branch }
                    }
                    error make { msg: $"($repo): push of branch ($branch) failed\n($pushed.stderr)" }
                }
                updateRemoteBranchRef $repo $branch $local
                return { online: true, state: "pushed", branch: $branch, diff: $diff, accepted: $base, candidate: $local }
            }
            { online: true, state: "both-moved", branch: $branch, local: $local, candidate: $candidate }
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
        # direct inputs of the working tree's flake.lock that HEAD's flake.lock does not have
        def newFlakeInputs [repo: string] {
            let inputs = { |lock|
                try {
                    let nodes = ($lock | from json)
                    $nodes.nodes | get $nodes.root | get inputs | columns
                } catch { [] }
            }
            let before = (do $inputs (gitSafe $repo show HEAD:flake.lock | complete | get stdout))
            let now = (do $inputs (try { open --raw $"($repo)/flake.lock" } catch { "" }))
            $now | where { |i| $i not-in $before }
        }
        def commitRepo [repo: string, message: string] {
            cd $repo
            # a new input is the quiet way for unknown code to enter the system: name it loudly before it is committed
            let newInputs = (newFlakeInputs $repo)
            if not ($newInputs | is-empty) {
                print -e $"(ansi red_bold)($repo): new flake inputs: ($newInputs | str join ' ')(ansi rst)"
            }
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
