# Usage: config-rename <message> [--host <host>] [--single (-s)]
def main [message: string, --host: string, --single(-s)] {
    let target = (currentRepo $host)
    let common = (repoPath "common")
    let newMsg = (buildMessage $message)

    # sync first, so the last commit and the lease are fresh
    repoSync $target
    repoSync $common

    let old = (gitSafe $target log -1 --format=%s | complete | get stdout | str trim)
    if $old == $newMsg {
        print "Same name"
        return
    }
    let withCommon = $target == $common or (not $single and (gitSafe $common log -1 --format=%s | complete | get stdout | str trim) == $old)

    if $withCommon and $target != $common {
        print $"Will be renamed in ($target | path basename) + common"
    } else {
        print $"Will be renamed only in ($target | path basename)"
    }
    let reply = (input "Rename? [Y/n]: " | str lowercase)
    if not ($reply == "" or $reply == "y" or $reply == "ye" or $reply == "yes") {
        return
    }

    if $withCommon {
        let oldCommonRev = (gitSafe $common rev-parse HEAD | complete | get stdout | str trim)
        silent { gitSafe $common commit --amend --allow-empty -m $newMsg }
        repoPush $common --no-retry
        if not $single {
            for repo in (hostRepos) {
                if (lockedRev $repo) == $oldCommonRev {
                    updateCommonLock $repo
                    # target's new lock goes into its amend below; other repos get their own commit
                    if $repo != $target {
                        commitRepo $repo $"($HOST): Common flake has been updated"
                        repoPush $repo
                    }
                }
            }
        }
    }
    if $target != $common {
        if not ((gitSafe $target status --porcelain -- flake.lock | complete | get stdout) | is-empty) {
            gitSafe $target add flake.lock
        }
        silent { gitSafe $target commit --amend --allow-empty -m $newMsg }
        repoPush $target --no-retry
    }
    fixPermissions
}
