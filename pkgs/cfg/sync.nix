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
                mut results = []
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate })
                            if $sync.state? == "catastrophe" {
                                $sync | upsert localInputs (localFlakeInputs $repo "worktree")
                            } else if not $sync.online {
                                { online: false, state: "offline", branch: $branch }
                            } else {
                                let changes = if $no_add {
                                    commitRepo $repo (buildMessage "Sync") --no-add
                                } else {
                                    { files: (worktreeFiles $repo), committed: false, inputs: (localFlakeInputs $repo "worktree") }
                                }
                                let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
                                let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
                                let commits = (commitsToPush $repo $remote $local)
                                let pushed = (repoPush $repo --report --on-rewrite { |accepted, candidate| confirmLocalRewrite $repo $accepted $candidate })
                                if $pushed.state == "catastrophe" {
                                    ((($pushed | upsert localFiles $changes.files) | upsert localInputs $changes.inputs) | upsert remoteDiff $sync.diff?) | upsert remoteInputs ($sync.remoteInputs? | default [])
                                } else {
                                    {
                                        online: $pushed.online
                                        state: (if $sync.state? == "rewritten" { "rewritten" } else if $pushed.state == "offline" { "local-ahead" } else { $pushed.state })
                                        branch: $branch
                                        diff: $sync.diff?
                                        localFiles: $changes.files
                                        localInputs: $changes.inputs
                                        remoteInputs: ($sync.remoteInputs? | default [])
                                        pushed: (if $pushed.state in [ "pushed" "offline" ] { $commits } else { [] })
                                    }
                                }
                            }
                        } else {
                            repoSyncBranch $repo $branch "sync" --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate } --on-local-rewrite { |accepted, candidate| confirmLocalRewrite $repo $accepted $candidate }
                        }
                    } catch { |e|
                        reportProblem $"($repo)/($branch)" ($e.msg? | default $"($e)")
                        null
                    })
                    if $res != null and $res.online and $res.state != "catastrophe" {
                        clearCatastropheMarker $repo $branch
                    }
                    if $res == null {
                        $ok = false
                    } else if not $res.online {
                        print $"($REPORT_COLOR.yellow)($repo)/($branch): offline, sync skipped($REPORT_COLOR.reset)"
                        $ok = false
                        break
                    } else if $res.state == "catastrophe" {
                        $ok = false
                    }
                    if $res != null and $res.online { $results = ($results | append { branch: $branch, result: $res }) }
                }
                let printed = (printRepoResults $repo $results)
                $anyPrinted = $anyPrinted or $printed
            }
            main perms
            if not $ok {
                exit 1
            }
            if not $anyPrinted { printEverythingUpToDate }
        }
''
