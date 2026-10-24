{ vars }:
''
        # Usage: cfg push [--host (-h) <host|cur|com>] [--quiet (-q)]
        def "main push" [--host(-h): string, --quiet(-q)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            mut anyPrinted = false
            for repo in $repos {
                let current = (repoBranch $repo)
                let branches = if $quiet { repoBranches $repo } else { [ $current ] }
                let batch = (runRepoBranches $repo $branches "push" { |repo, branch|
                    if $branch == $current {
                        let sync = (repoSync $repo)
                        if $sync.state? == "catastrophe" {
                            $sync
                        } else if not $sync.online {
                            (branchResult $branch false "offline")
                        } else {
                            let files = (worktreeFiles $repo)
                            let inputs = (localFlakeInputs $repo "worktree")
                            let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")
                            let local = (gitOut $repo rev-parse HEAD)
                            let commits = (commitsToPush $repo $remote $local)
                            let pushed = (repoPush $repo --report)
                            if $pushed.state == "catastrophe" { ((($pushed | upsert localFiles $files) | upsert localInputs $inputs) | upsert remoteDiff $sync.diff?) | upsert remoteInputs ($sync.remoteInputs? | default []) } else { branchReport $sync $pushed $branch $files $inputs $commits }
                        }
                    } else {
                        repoSyncBranch $repo $branch "push"
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
''
