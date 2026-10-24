{ vars }:
''
        # Usage: cfg sync [--host (-h) <host|cur|com>] [--all (-a)]
        # what cfg-sync.service does, by hand: pull then push each repo. The only command that may take a
        # rewritten origin history, and only after confirmRewrite showed the damage and got a "yes"
        def "main sync" [--host(-h): string, --all(-a)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            for repo in $repos {
                let current = (repoBranch $repo)
                let branches = if $all { repoBranches $repo } else { [ $current ] }
                printRepoHeading $repo
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --quiet-catastrophe --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate })
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
                            repoSyncBranch $repo $branch "sync" --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate }
                        }
                    } catch { |e|
                        reportProblem $"($repo)/($branch)" ($e.msg? | default $"($e)")
                        null
                    })
                    if $res == null {
                        $ok = false
                    } else if not $res.online {
                        print $"(ansi yellow)($repo)/($branch): offline, sync skipped(ansi rst)"
                        break
                    } else if $res.state == "catastrophe" {
                        printBranchResult $repo $branch $res
                        $ok = false
                    } else {
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
