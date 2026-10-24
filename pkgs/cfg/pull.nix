{ vars }:
''
        # Usage: cfg pull [--host (-h) <host|cur|com>] [--quiet (-q)]
        def "main pull" [--host(-h): string, --quiet(-q)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            mut anyPrinted = false
            for repo in $repos {
                let current = (repoBranch $repo)
                let branches = if $quiet { repoBranches $repo } else { [ $current ] }
                let batch = (runRepoBranches $repo $branches "pull" { |repo, branch|
                    if $branch == $current {
                        let sync = (repoSync $repo)
                        if $sync.state? == "catastrophe" { $sync | upsert localInputs (localFlakeInputs $repo "worktree") } else { { online: $sync.online, state: ($sync.state? | default "up-to-date"), branch: $branch, diff: $sync.diff?, localFiles: (worktreeFiles $repo), localInputs: (localFlakeInputs $repo "worktree"), remoteInputs: ($sync.remoteInputs? | default []) } }
                    } else {
                        repoSyncBranch $repo $branch "pull"
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
