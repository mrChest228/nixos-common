{ config, lib, com, pkgs, vars, self, ... }: {
    conf.subcommands.pull = ''
        # Usage: conf pull [--host (-h) <host>] [--quiet (-q)]
        def "main pull" [--host(-h): string, --quiet(-q)] {
            checkNoForeign
            let repos = if ($host | is-not-empty) { [ $"${vars.configPath}/($host)" ] } else { [ "${vars.configPath}/common" ] ++ (hostRepos) }
            mut ok = true
            for repo in $repos {
                let res = (try {
                    repoSync $repo
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
                }
            }
            main perms
            if not $ok {
                exit 1
            }
        }
    '';
}
