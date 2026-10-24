{ vars }:
''
        # Usage: cfg sync [--host (-h) <host|cur|com>] [--all (-a)] [--no-add (-n)]
        # what cfg-sync.service does, by hand: pull then push each repo. The only command that may take a
        # rewritten origin history, and only after confirmRewrite showed the damage and got a "yes"
        def "main sync" [--host(-h): string, --all(-a), --no-add(-n)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            mut anyPrinted = false
            for repo in $repos {
                let current = (repoBranch $repo)
                let branches = if $all { repoBranches $repo } else { [ $current ] }
                let batch = (runRepoBranches $repo $branches "sync" { |repo, branch|
                    if $branch == $current {
                        let fetched = (repoSync $repo)
                        let sync = if $fetched.state? == "catastrophe" and (confirmRewrite $repo $fetched.accepted $fetched.candidate) {
                            applyRepoSync $repo $fetched.gitDir $branch $fetched.accepted $fetched.candidate $fetched.diff $fetched.remoteInputs --rewritten
                        } else {
                            $fetched
                        }
                        if $sync.state? == "catastrophe" {
                            $sync | upsert localInputs (localFlakeInputs $repo "worktree")
                        } else if not $sync.online {
                            (branchResult $branch false "offline")
                        } else {
                            let changes = if $no_add {
                                commitRepo $repo (buildMessage "Sync") --no-add
                            } else {
                                { files: (worktreeFiles $repo), committed: false, inputs: (localFlakeInputs $repo "worktree") }
                            }
                            let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")
                            let local = (gitOut $repo rev-parse HEAD)
                            let commits = (commitsToPush $repo $remote $local)
                            let pushed = (repoPush $repo --report --on-rewrite { |accepted, candidate| confirmLocalRewrite $repo $accepted $candidate })
                            if $pushed.state == "catastrophe" { ((($pushed | upsert localFiles $changes.files) | upsert localInputs $changes.inputs) | upsert remoteDiff $sync.diff?) | upsert remoteInputs ($sync.remoteInputs? | default []) } else { branchReport $sync $pushed $branch $changes.files $changes.inputs $commits }
                        }
                    } else {
                        repoSyncBranch $repo $branch "sync" --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate } --on-local-rewrite { |accepted, candidate| confirmLocalRewrite $repo $accepted $candidate }
                    }
                })
                $ok = $ok and $batch.ok
                let printed = (printRepoResults $repo $batch.results)
                $anyPrinted = $anyPrinted or $printed
            }
            main perms
            if not $ok { exit 1 }
            if not $anyPrinted { printEverythingUpToDate }
        }
''
