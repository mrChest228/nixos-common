{ vars }:
''
        # Usage: cfg pull [--host (-h) <host|cur|com>] [--quiet (-q)]
        def "main pull" [--host(-h): string, --quiet(-q)] {
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
                            { online: $sync.online, state: (if $sync.changed { "updated" } else { "up-to-date" }), branch: $branch }
                        } else {
                            repoSyncBranch $repo $branch "pull"
                        }
                    } catch { |e|
                        reportProblem $repo ($e.msg? | default $"($e)") --quiet=$quiet
                        null
                    })
                    if $res == null {
                        $ok = false
                    } else if not $res.online {
                        if not $quiet {
                            print $"(ansi yellow)($repo): offline, pull skipped(ansi rst)"
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
