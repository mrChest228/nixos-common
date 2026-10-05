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
        # amend needs --allow-empty: the last commit may carry no changes
        silent { gitSafe $common commit --amend --allow-empty -m $newMsg }
        # a rejected push stops the rename instead of retrying with half-renamed repos
        repoPush $common --no-retry
        if not $single {
            for repo in (hostRepos) {
                # repos still locked on the old common rev get their lock bumped
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
        # same --allow-empty reason as above
        silent { gitSafe $target commit --amend --allow-empty -m $newMsg }
        repoPush $target --no-retry
    }
    fixPermissions
}
