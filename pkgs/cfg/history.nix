{ pkgs, vars }:
''
        def commitRecords [records: list<record>] {
            $records | each { |entry| { hash: $entry.hash, subject: $entry.subject, date: $entry.date } }
        }
        def historyRange [repo: string, range: string] {
            let result = (gitSafe $repo log --reverse --first-parent '--format=%H%x1f%T%x1f%s%x1f%ad%x1f%P' '--date=format:%Y-%m-%d %H:%M:%S' $range | complete)
            if $result.exit_code != 0 { error make { msg: $"($repo): history read failed\n($result.stderr)" } }
            $result.stdout | lines | each { |line|
                let fields = ($line | split row "\u{1f}")
                { hash: ($fields | get 0), tree: ($fields | get 1), subject: ($fields | get 2), date: ($fields | get 3), parents: ($fields | get 4) }
            }
        }
        def historyCommits [repo: string, hashes: list<string>] {
            if ($hashes | is-empty) { return [] }
            let result = (gitSafe $repo log --no-walk=unsorted '--format=%H%x1f%s%x1f%ad' '--date=format:%Y-%m-%d %H:%M:%S' ...$hashes | complete)
            if $result.exit_code != 0 { error make { msg: $"($repo): history read failed\n($result.stderr)" } }
            let records = ($result.stdout | lines | each { |line|
                let fields = ($line | split row "\u{1f}")
                { hash: ($fields | get 0), subject: ($fields | get 1), date: ($fields | get 2) }
            })
            $hashes | each { |hash| $records | where hash == $hash | first }
        }
        def commitsToPush [repo: string, remote: string, local: string] {
            if $remote == "" {
                historyCommits $repo (gitSafe $repo rev-list --reverse --first-parent $local | complete | get stdout | lines)
            } else {
                let diff = (historyDiff $repo $remote $local)
                $diff.events | each { |event|
                    if $event.kind == "added" { $event.commit } else { { hash: $event.newHash, subject: $event.newSubject, date: $event.date } }
                }
            }
        }
        # checks first-parent trees, allowing message-only renames but no deleted or changed commits
        def historyDiff [repo: string, accepted: string, candidate: string] {
            if (gitSafe $repo merge-base --is-ancestor $accepted $candidate | complete | get exit_code) == 0 {
                let added = (commitRecords (historyRange $repo $"($accepted)..($candidate)"))
                return (historyResult $repo true [] $added ($added | each { |commit| { kind: "added", commit: $commit } }))
            }

            let mergeBase = (gitSafe $repo merge-base $accepted $candidate | complete)
            let base = if $mergeBase.exit_code == 0 { $mergeBase.stdout | str trim } else { null }
            let aRange = if $base == null { $accepted } else { $"($base)..($accepted)" }
            let bRange = if $base == null { $candidate } else { $"($base)..($candidate)" }
            let aRecords = (historyRange $repo $aRange)
            let bRecords = (historyRange $repo $bRange)
            let aMerges = ($aRecords | where { |entry| (($entry.parents | split row " ") | length) > 1 })
            let bMerges = ($bRecords | where { |entry| (($entry.parents | split row " ") | length) > 1 })
            let pairedCount = ([$aRecords $bRecords] | each { |records| $records | length } | math min)
            mut mismatch = -1
            mut rewriteEvents = []
            for entry in ($aRecords | enumerate | take $pairedCount) {
                let old = $entry.item
                let new = ($bRecords | get $entry.index)
                if $old.tree != $new.tree {
                    $mismatch = $entry.index
                    break
                }
                if $old.hash != $new.hash {
                    let event = { kind: (if $old.subject != $new.subject { "renamed" } else { "rehashed" }), oldHash: $old.hash, newHash: $new.hash, oldSubject: $old.subject, newSubject: $new.subject, date: $new.date }
                    $rewriteEvents = ($rewriteEvents | append $event)
                }
            }
            if $mismatch < 0 and ($bRecords | length) < ($aRecords | length) { $mismatch = $pairedCount }
            let kept = $mismatch < 0 and ($aMerges | is-empty) and ($bMerges | is-empty)
            let start = if $mismatch < 0 { 0 } else { $mismatch }
            let deleted = if $kept { [] } else { commitRecords ($aRecords | skip $start) }
            let added = if $kept { commitRecords ($bRecords | skip ($aRecords | length)) } else { commitRecords ($bRecords | skip $start) }
            let events = if $kept {
                $rewriteEvents ++ ($added | each { |commit| { kind: "added", commit: $commit } })
            } else {
                []
            }
            historyResult $repo $kept $deleted $added $events
        }
        # a lock entry with the same rev but another narHash can't come from an honest update: treated like deleted history
        def lockTampered [repo: string, commits: list<record>] {
            $commits | any { |commit| (commitFlakeInputs $repo $commit.hash).changes | any { |change| $change.kind == "narHash" } }
        }
        def historyResult [repo: string, kept: bool, deleted: list<record>, added: list<record>, events: list<record>] {
            if $kept and (lockTampered $repo $added) { return { kept: false, reason: "narHash", deleted: [], added: $added, events: [] } }
            { kept: $kept, reason: (if $kept { "" } else { "history" }), deleted: $deleted, added: $added, events: $events }
        }
        # Confirm before accepting a rewritten history.
        def confirmRewrite [repo: string, accepted: string, candidate: string] {
            let sudoUser = ($env.SUDO_USER? | default "")
            if not (is-admin) or ($sudoUser | is-empty) or not (is-terminal --stdin) { return false }
            let diff = (historyDiff $repo $accepted $candidate)
            printRepoHeading $repo
            printBranchHeading (repoBranch $repo)
            printSectionHeading "remote"
            printCatastrophe $repo $diff
            (input "take origin's history? type yes: " | str trim) == "yes"
        }
        def confirmLocalRewrite [repo: string, accepted: string, candidate: string] {
            let sudoUser = ($env.SUDO_USER? | default "")
            if not (is-admin) or ($sudoUser | is-empty) or not (is-terminal --stdin) { return false }
            let diff = (historyDiff $repo $accepted $candidate)
            printRepoHeading $repo
            printBranchHeading (repoBranch $repo)
            printSectionHeading "local"
            printCatastrophe $repo $diff
            (input "push local history? type yes: " | str trim) == "yes"
        }
''
