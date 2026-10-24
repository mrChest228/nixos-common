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
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo)
                            if not $sync.online {
                                { online: false, state: "offline", branch: $branch }
                            } else {
                                let pushed = (repoPush $repo)
                                { online: $pushed, state: (if $pushed { "pushed" } else { "offline" }), branch: $branch }
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
                        reportProblem $"($repo)/($branch)" "origin history was rewritten; branch skipped" --quiet=$quiet
                        $ok = false
                    } else if $res.state == "both-moved" {
                        print $"(ansi yellow)($repo)/($branch): both local and origin have new commits, switch to it to sync(ansi rst)"
                    }
                }
            }
            main perms
            if not $ok {
                exit 1
            }
        }
''
