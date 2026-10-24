{ vars }:
''
        # Usage: cfg rename <message> [n] [--host (-h) <host|cur|com>] [--single (-s)] [--help]
        # n is an optional negative offset: omitted or -0 renames HEAD; -1 renames its parent.
        const RENAME_USAGE = "Usage: cfg rename <message> [n] [--host (-h) <host|cur|com>] [--single (-s)] [--help]"
        def parseRenameArgs [args: list<string>] {
            mut offset = 0
            mut hasOffset = false
            mut host = ""
            mut hasHost = false
            mut single = false
            mut messages = []
            mut i = 0
            loop {
                if $i >= ($args | length) { break }
                let arg = ($args | get $i)
                if $arg == "--help" {
                    print $RENAME_USAGE
                    return null
                } else if $arg in [ "--host" "-h" ] {
                    if $hasHost or ($i + 1) >= ($args | length) {
                        error make { msg: $RENAME_USAGE }
                    }
                    $i = $i + 1
                    $host = ($args | get $i)
                    $hasHost = true
                } else if $arg in [ "--single" "-s" ] {
                    $single = true
                } else if $arg =~ '^-\d+$' {
                    if $hasOffset {
                        error make { msg: $RENAME_USAGE }
                    }
                    $offset = ($arg | into int)
                    $hasOffset = true
                } else {
                    $messages = ($messages | append $arg)
                }
                $i = $i + 1
            }
            if ($messages | length) != 1 {
                error make { msg: $RENAME_USAGE }
            }
            {
                message: ($messages | first)
                offset: $offset
                host: $host
                single: $single
            }
        }
        def historyCommit [repo: string, old: string, parent: string, message: string] {
            let tree = (gitSafe $repo rev-parse $"($old)^{tree}" | complete | get stdout | str trim)
            let author = {
                name: (gitSafe $repo log -1 --format=%an $old | complete | get stdout | str trim)
                email: (gitSafe $repo log -1 --format=%ae $old | complete | get stdout | str trim)
                date: (gitSafe $repo log -1 --format=%aI $old | complete | get stdout | str trim)
            }
            let result = (with-env {
                GIT_AUTHOR_NAME: $author.name
                GIT_AUTHOR_EMAIL: $author.email
                GIT_AUTHOR_DATE: $author.date
            } {
                if $parent == "" {
                    $message | gitSafe $repo commit-tree $tree -F - | complete
                } else {
                    $message | gitSafe $repo commit-tree $tree -p $parent -F - | complete
                }
            })
            if $result.exit_code != 0 {
                error make { msg: $"($repo): commit-tree failed\n($result.stderr)" }
            }
            $result.stdout | str trim
        }
        def rewriteCommitHistory [repo: string, target: string, message: string] {
            let head = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            if (gitSafe $repo merge-base --is-ancestor $target $head | complete | get exit_code) != 0 {
                error make { msg: $"($repo): rename target is not an ancestor of HEAD" }
            }
            let targetParents = (gitSafe $repo rev-list --parents -n 1 $target | complete | get stdout | str trim | split row " ")
            if ($targetParents | length) > 2 {
                error make { msg: $"($repo): cannot rename a merge commit" }
            }
            let merges = (gitSafe $repo rev-list --merges $"($target)..($head)" | complete | get stdout | lines)
            if ($merges | is-not-empty) {
                error make { msg: $"($repo): cannot rename across merge commits" }
            }
            let parentResult = (gitSafe $repo rev-parse -q --verify $"($target)^" | complete)
            let parent = if $parentResult.exit_code == 0 { $parentResult.stdout | str trim } else { "" }
            let targetMessage = ($message + "\n")
            mut newHead = (historyCommit $repo $target $parent $targetMessage)
            let later = (gitSafe $repo rev-list --reverse $"($target)..($head)" | complete | get stdout | lines)
            for old in $later {
                let raw = (gitSafe $repo cat-file commit $old | complete | get stdout)
                let separator = ($raw | str index-of "\n\n")
                let oldMessage = ($raw | str substring ($separator + 2)..)
                $newHead = (historyCommit $repo $old $newHead $oldMessage)
            }
            gitSafe $repo update-ref HEAD $newHead $head
            $newHead
        }
        def --wrapped "main rename" [...args: string] {
            let parsed = (parseRenameArgs $args)
            if $parsed == null { return }
            let message = $parsed.message
            let offset = $parsed.offset
            let host = $parsed.host
            let single = $parsed.single
            checkNoForeign
            let target = (currentRepo $host --single=$single)
            let common = "${vars.configPath}/common"
            let newMsg = (buildMessage $message)
            let distance = if $offset < 0 { 0 - $offset } else { $offset }

            # sync first, so the last commit and the lease are fresh
            repoSync $target
            repoSync $common

            let targetRevision = if $distance == 0 {
                gitSafe $target rev-parse HEAD | complete | get stdout | str trim
            } else {
                let result = (gitSafe $target rev-parse -q --verify $"HEAD~($distance)" | complete)
                if $result.exit_code != 0 {
                    error make { msg: $"($target): rename offset ($offset) is outside the history" }
                }
                $result.stdout | str trim
            }
            let old = (gitSafe $target log -1 --format=%s $targetRevision | complete | get stdout | str trim)
            if $old == $newMsg {
                print "Same name"
                return
            }
            let commonRevision = if $distance == 0 {
                gitSafe $common rev-parse HEAD | complete | get stdout | str trim
            } else {
                let result = (gitSafe $common rev-parse -q --verify $"HEAD~($distance)" | complete)
                if $result.exit_code == 0 { $result.stdout | str trim } else { null }
            }
            let commonOld = if $commonRevision == null {
                ""
            } else {
                gitSafe $common log -1 --format=%s $commonRevision | complete | get stdout | str trim
            }
            let withCommon = $target == $common or (not $single and $commonOld == $old)

            if $withCommon and $target != $common {
                print $"Will be renamed in ($target | path basename) + common"
            } else {
                print $"Will be renamed only in ($target | path basename)"
            }
            let reply = (input "Rename? [Y/n]: " | str lowercase)
            if not ($reply == "" or $reply == "y" or $reply == "ye" or $reply == "yes") {
                return
            }

            mut targetRelocked = false
            if $withCommon {
                let oldCommonRev = (gitSafe $common rev-parse HEAD | complete | get stdout | str trim)  # common's hash before the rewrite
                if $distance == 0 {
                    # amend needs --allow-empty: the last commit may carry no changes
                    silent { gitSafe $common commit --amend --allow-empty -m $newMsg }
                } else {
                    rewriteCommitHistory $common $commonRevision $newMsg
                }
                # a rejected push stops the rename instead of retrying with half-renamed repos
                repoPush $common --no-retry
                if not $single {
                    for repo in (hostRepos) {
                        # repos still locked on the old common rev get their lock bumped
                        if (lockedRev $repo) == $oldCommonRev {
                            updateCommonLock $repo
                            # target's new lock goes into its amend below; other repos get their own commit
                            if $repo != $target {
                                commitAndPush $repo $"${vars.host}: Common flake has been updated"
                            } else {
                                $targetRelocked = true
                            }
                        }
                    }
                }
            }
            if $target != $common {
                if $distance == 0 {
                    # only an uncommitted lock change gets staged into the amend
                    if not ((gitSafe $target status --porcelain -- flake.lock | complete | get stdout) | is-empty) {
                        gitSafe $target add flake.lock
                    }
                    # same --allow-empty reason as above
                    silent { gitSafe $target commit --amend --allow-empty -m $newMsg }
                } else {
                    rewriteCommitHistory $target $targetRevision $newMsg
                    if $targetRelocked and not ((gitSafe $target status --porcelain -- flake.lock | complete | get stdout) | is-empty) {
                        gitSafe $target add flake.lock
                        silent { gitSafe $target commit --only -m $"${vars.host}: Common flake has been updated" -- flake.lock }
                    }
                }
                repoPush $target --no-retry
            }
            main perms
        }
''
