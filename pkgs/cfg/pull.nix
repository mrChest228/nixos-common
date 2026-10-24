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
                printRepoHeading $repo
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --quiet-catastrophe)
                            if $sync.state? == "catastrophe" {
                                $sync
                            } else {
                                { online: $sync.online, state: (if $sync.changed { "updated" } else { "up-to-date" }), branch: $branch, diff: $sync.diff? }
                            }
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
