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
                for branch in $branches {
                    let res = (try {
                        if $branch == $current {
                            let sync = (repoSync $repo --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate })
                            if not $sync.online {
                                { online: false, state: "offline", branch: $branch }
                            } else {
                                let pushed = (repoPush $repo)
                                { online: $pushed, state: (if $pushed { "synced" } else { "offline" }), branch: $branch }
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
                        reportProblem $"($repo)/($branch)" "origin history was rewritten; branch skipped"
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
