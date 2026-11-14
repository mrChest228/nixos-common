{ vars }:
''
        # Usage: cfg sync [--host (-h) <host|cur|com>] [--all (-a)] [--branch (-b) <branch>] [--quiet (-q)]
        # fetch + rebase, then push, per branch. Default: the current branch of every repo (or of --host);
        # --all: every local branch; --branch: that branch where it exists locally, without checkout.
        # The only command that may take a rewritten history, and only after confirmRewrite/confirmLocalRewrite
        # showed the damage in a terminal and got a "yes". --quiet is what cfg-sync.service runs: all branches,
        # markers instead of repeated catastrophe reports, no questions.
        def "main sync" [--host(-h): string, --all(-a), --branch(-b): string, --quiet(-q)] {
            checkNoForeign
            if $all and ($branch | is-not-empty) { error make { msg: "--all and --branch can't be used together" } }
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            mut anyPrinted = false
            for repo in $repos {
                if $quiet and (fetchedWithin $repo 90sec) { continue }  # the NM hook may fire right after a timer run
                let current = (repoBranch $repo)
                let local = (repoBranches $repo)
                let branches = if ($branch | is-not-empty) {
                    if $branch in $local { [ $branch ] } else { [] }
                } else if $all or $quiet { $local } else { [ $current ] }
                let batch = (runRepoBranches $repo $branches { |repo, branch|
                    if $branch == $current {
                        syncCurrentBranch $repo $branch --quiet=$quiet
                    } else if $quiet {
                        repoSyncBranch $repo $branch
                    } else {
                        repoSyncBranch $repo $branch --on-rewrite { |a, c| confirmRewrite $repo $a $c } --on-local-rewrite { |a, c| confirmLocalRewrite $repo $a $c }
                    }
                } --quiet=$quiet)
                $ok = $ok and $batch.ok
                let printed = (printRepoResults $repo $batch.results --quiet=$quiet)
                $anyPrinted = $anyPrinted or $printed
            }
            main perms
            if not $ok { exit 1 }
            if not $quiet and not $anyPrinted { printEverythingUpToDate }
        }
        # the checked-out branch: rebase the worktree (autostash), then push; --quiet never accepts rewrites
        def syncCurrentBranch [repo: string, branch: string, --quiet] {
            let fetched = (repoSync $repo)
            let sync = if $fetched.state? == "catastrophe" and not $quiet and (confirmRewrite $repo $fetched.accepted $fetched.candidate) {
                applyRepoSync $repo $fetched.gitDir $branch $fetched.accepted $fetched.candidate $fetched.diff --rewritten
            } else {
                $fetched
            }
            if $sync.state? == "catastrophe" { return $sync }
            if not $sync.online { return (branchResult $branch false "offline") }
            let files = (worktreeFiles $repo)
            let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")
            let local = (gitOut $repo rev-parse HEAD)
            let commits = (commitsToPush $repo $remote $local)
            let pushed = if $quiet { repoPush $repo --report } else { repoPush $repo --report --on-rewrite { |a, c| confirmLocalRewrite $repo $a $c } }
            if $pushed.state == "catastrophe" { ($pushed | upsert localFiles $files) | upsert remoteDiff $sync.diff? } else { branchReport $sync $pushed $branch $files $commits }
        }
''
