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
                mut results = []
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo)
                            if $sync.state? == "catastrophe" {
                                $sync
                            } else if not $sync.online {
                                { online: false, state: "offline", branch: $branch }
                            } else {
                                let files = (worktreeFiles $repo)
                                let inputs = (localFlakeInputs $repo "worktree")
                                let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
                                let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
                                let commits = (commitsToPush $repo $remote $local)
                                let pushed = (repoPush $repo --report)
                                if $pushed.state == "catastrophe" {
                                    ((($pushed | upsert localFiles $files) | upsert localInputs $inputs) | upsert remoteDiff $sync.diff?) | upsert remoteInputs ($sync.remoteInputs? | default [])
                                } else {
                                    {
                                        online: $pushed.online
                                        state: (if $sync.state? == "rewritten" { "rewritten" } else if $pushed.state == "offline" { "local-ahead" } else { $pushed.state })
                                        branch: $branch
                                        diff: $sync.diff?
                                        localFiles: $files
                                        localInputs: $inputs
                                        remoteInputs: ($sync.remoteInputs? | default [])
                                        pushed: (if $pushed.state in [ "pushed" "offline" ] { $commits } else { [] })
                                    }
                                }
                            }
                        } else {
                            repoSyncBranch $repo $branch "push"
                        }
                    } catch { |e|
                        reportProblem $repo ($e.msg? | default $"($e)") --quiet=$quiet
                        null
                    })
                    if $res == null {
                        $ok = false
                    } else if not $res.online {
                        if not $quiet {
                            print $"($REPORT_COLOR.yellow)($repo): offline, push skipped($REPORT_COLOR.reset)"
                        }
                        break
                    } else if $res.state == "catastrophe" {
                        $ok = false
                    } else {
                        clearCatastropheMarker $repo $branch
                    }
                    if $res != null and $res.online { $results = ($results | append { branch: $branch, result: $res }) }
                }
                let printed = (printRepoResults $repo $results --quiet=$quiet)
                $anyPrinted = $anyPrinted or $printed
            }
            main perms
            if not $ok {
                exit 1
            }
            if not $quiet and not $anyPrinted { printEverythingUpToDate }
        }
''
