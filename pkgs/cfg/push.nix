{ vars }:
''
        # Usage: cfg push [--host (-h) <host|cur|com>] [--quiet (-q)]
        def "main push" [--host(-h): string, --quiet(-q)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            for repo in $repos {
                let current = (repoBranch $repo)
                let branches = if $quiet { repoBranches $repo } else { [ $current ] }
                if not $quiet { printRepoHeading $repo }
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --quiet-catastrophe)
                            if $sync.state? == "catastrophe" {
                                $sync
                            } else if not $sync.online {
                                { online: false, state: "offline", branch: $branch }
                            } else {
                                let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
                                let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
                                let commits = (commitsToPush $repo $remote $local)
                                let pushed = (repoPush $repo --report)
                                { online: $pushed, state: (if $pushed { "pushed" } else { "offline" }), branch: $branch, diff: $sync.diff?, pushed: (if $pushed { $commits } else { [] }) }
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
                            print $"(ansi yellow)($repo): offline, push skipped(ansi rst)"
                        }
                        break
                    } else if $res.state == "catastrophe" {
                        if $quiet {
                            printQuietCatastrophe $repo $branch $res
                        } else {
                            printBranchResult $repo $branch $res
                        }
                        $ok = false
                    } else {
                        if $quiet { clearCatastropheMarker $repo $branch }
                        printBranchResult $repo $branch $res
                    }
                }
            }
            main perms
            if not $ok {
                exit 1
            }
        }
''
