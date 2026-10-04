# Usage: config-pull [--host <host>] [--quiet (-q)]
def main [--host: string, --quiet(-q)] {
    let repos = if ($host | is-not-empty) { [ (repoPath $host) ] } else { [ (repoPath "common") ] ++ (hostRepos) }
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
    fixPermissions
    if not $ok {
        exit 1
    }
}
