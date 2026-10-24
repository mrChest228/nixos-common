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
                mut results = []
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --quiet-catastrophe)
                            if $sync.state? == "catastrophe" {
                                $sync
                            } else {
                                { online: $sync.online, state: ($sync.state? | default "up-to-date"), branch: $branch, diff: $sync.diff?, localFiles: (worktreeFiles $repo) }
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
