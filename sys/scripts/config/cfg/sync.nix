{ vars }:
''
        # Usage: cfg sync [--host (-h) <host|cur|com>]
        # what cfg-sync.service does, by hand: pull then push each repo. The only command that may take a
        # rewritten origin history, and only after confirmRewrite showed the damage and got a "yes"
        def "main sync" [--host(-h): string] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ (hostRepo $host) ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            for repo in $repos {
                let res = (try {
                    repoSync $repo --on-rewrite { |accepted, candidate| confirmRewrite $repo $accepted $candidate }
                } catch { |e|
                    reportProblem $repo ($e.msg? | default $"($e)")
                    null
                })
                if $res == null {
                    $ok = false
                } else if not $res.online {
                    print $"(ansi yellow)($repo): offline, sync skipped(ansi rst)"
                    break
                } else {
                    let pushed = (try {
                        repoPush $repo
                    } catch { |e|
                        reportProblem $repo ($e.msg? | default $"($e)")
                        null
                    })
                    if $pushed == null {
                        $ok = false
                    } else if not $pushed {
                        print $"(ansi yellow)($repo): offline, push skipped(ansi rst)"
                        break
                    }
                }
            }
            main perms
            if not $ok {
                exit 1
            }
        }
''
