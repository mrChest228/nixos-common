{ pkgs, vars }:
''
        const REPORT_INDENT = {
            branch: "   "
            section: "      "
            item: "         "
            detail: "            "
        }
        const REPORT_COLOR = {
            reset: (ansi --escape '0m')
            repo: (ansi --escape '1;37m')
            branch: (ansi --escape '34m')
            section: (ansi --escape '3;36m')
            red: (ansi --escape '31m')
            redBold: (ansi --escape '1;31m')
            green: (ansi --escape '32m')
            greenBold: (ansi --escape '1;32m')
            yellow: (ansi --escape '33m')
            yellowBold: (ansi --escape '1;33m')
            cyan: (ansi --escape '36m')
            magenta: (ansi --escape '35m')
            magentaBold: (ansi --escape '1;35m')
            orangeBold: (ansi --escape '1;38;5;208m')
            blue: (ansi --escape '34m')
            white: (ansi --escape '37m')
            darkGray: (ansi --escape '90m')
        }
        # all host repos in ${vars.configPath} (git repos other than common; the cur mount is not a separate repo)
        def hostRepos [] {
            ls ${vars.configPath} | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) not-in [ "common" "cur" ] }
        }
        # --host aliases: `cur` is this host's repo, `com`/`common` the common one; else a repo name under the config dir
        def hostRepo [host: string] {
            let dir = (if $host == "cur" { "${vars.host}" } else if $host in [ "com" "common" ] { "common" } else { $host })
            let repo = $"${vars.configPath}/($dir)"
            if not ($"($repo)/.git" | path exists) {
                error make { msg: $"($repo) is not a config repo" }
            }
            $repo
        }
        # repo to act on: --host wins; otherwise resolved by walking up from PWD and comparing device+inode,
        # so a bind mount (e.g. a directory bound to another host repo) resolves to the real repo; fallback is the host repo.
        # PWD inside common resolves to the host repo — common is touched alone only via --host com or --single
        def currentRepo [host?: string, --single] {
            if ($host | is-not-empty) {
                return (hostRepo $host)
            }
            let repos = ([ $"${vars.configPath}/common" ] ++ (hostRepos))
            # stat -L follows symlinks: device:inode of the dir itself
            let repoIds = $repos | each { |r| (^${pkgs.coreutils}/bin/stat -L -c '%d:%i' $r | complete | get stdout | str trim) }
            mut p = ($env.PWD | path expand)
            loop {
                let id = (^${pkgs.coreutils}/bin/stat -L -c '%d:%i' $p | complete | get stdout | str trim)
                let hits = ($repoIds | enumerate | where { |x| $x.item == $id })
                if ($hits | is-not-empty) {
                    let hit = ($repos | get $hits.0.index)
                    if $hit == $"${vars.configPath}/common" and not $single { break }
                    return $hit
                }
                let parent = ($p | path dirname)
                if $parent == $p { break }
                $p = $parent
            }
            $"${vars.configPath}/${vars.host}"
        }
        # refuses to touch a repo mid-rebase or on a detached HEAD
        def checkRepoState [repo: string] {
            let gitDir = (gitSafe $repo rev-parse --git-dir | complete | get stdout | str trim)  # .git dir path, relative to the repo
            if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
                error make { msg: $"($repo): rebase in progress, finish it first" }
            }
            if (gitSafe $repo symbolic-ref -q HEAD | complete | get exit_code) != 0 {  # fails on detached HEAD
                error make { msg: $"($repo): detached HEAD" }
            }
            $gitDir
        }
        # name of the checked-out branch; every repo is synced with the same-named branch on origin
        def repoBranch [repo: string] {
            gitSafe $repo symbolic-ref -q --short HEAD | complete | get stdout | str trim
        }
        def fetchCandidate [repo: string, branch: string] {
            let result = (gitSafe $repo fetch --refmap= origin $"+refs/heads/($branch):refs/remotes/origin/candidate" | complete)
            if $result.exit_code == 0 {
                { online: true, state: "fetched", candidate: (gitSafe $repo rev-parse origin/candidate | complete | get stdout | str trim) }
            } else if (isNetworkError $result.stderr) {
                { online: false, state: "offline" }
            } else if ($result.stderr | str contains "couldn't find remote ref") {
                { online: true, state: "missing" }
            } else {
                error make { msg: $"($repo): fetch failed\n($result.stderr)" }
            }
        }
        def pushCandidate [repo: string, branch: string, source: string, accepted: string] {
            let lease = $"--force-with-lease=refs/heads/($branch):($accepted)"
            let result = (gitSafe $repo push $lease origin $"($source):refs/heads/($branch)" | complete)
            if $result.exit_code == 0 {
                { online: true, state: "pushed" }
            } else if (isNetworkError $result.stderr) {
                print ($REPORT_COLOR.yellow + $repo + ": not pushed (offline), will be pushed later" + $REPORT_COLOR.reset)
                { online: false, state: "offline" }
            } else {
                { online: true, state: "rejected", stderr: $result.stderr }
            }
        }
        def pushHistoryState [repo: string, accepted: string, candidate: string, onRewrite: any] {
            let diff = if $accepted == "" { null } else { historyDiff $repo $accepted $candidate }
            let invalid = ($diff != null) and not $diff.kept
            let rewritten = $invalid and $onRewrite != null and (do $onRewrite $accepted $candidate)
            { diff: $diff, catastrophe: ($invalid and not $rewritten) }
        }
        def repoBranches [repo: string] {
            gitSafe $repo for-each-ref '--format=%(refname:short)' refs/heads/ | complete | get stdout | lines
        }
        def updateRemoteBranchRef [repo: string, branch: string, rev: string] {
            let ref = $"refs/remotes/origin/($branch)"
            let current = (gitSafe $repo rev-parse -q --verify $ref | complete)
            if $current.exit_code == 0 {
                let old = ($current.stdout | str trim)
                if $old != $rev {
                    gitSafe $repo update-ref $ref $rev $old
                }
            } else {
                gitSafe $repo update-ref $ref $rev
            }
        }
        def unicodeOutput [] {
            let term = ($env.TERM? | default "")
            let locales = [ ($env.LC_ALL? | default "") ($env.LC_CTYPE? | default "") ($env.LANG? | default "") ]
            ($term != "linux") and ($locales | any { |locale|
                let value = ($locale | str lowercase)
                ($value | str contains "utf-8") or ($value | str contains "utf8")
            })
        }
        def glyph [uni: string, ascii: string] {
            if (unicodeOutput) { $uni } else { $ascii }
        }
        def sourceChangeColor [] {
            if (unicodeOutput) { $REPORT_COLOR.orangeBold } else { $REPORT_COLOR.yellowBold }
        }
        def changeMark [letter: string] {
            {
                text: $letter
                color: (match $letter {
                    "A" => $REPORT_COLOR.green
                    "M" => $REPORT_COLOR.yellow
                    "D" => $REPORT_COLOR.red
                    "R" => $REPORT_COLOR.cyan
                    "C" => $REPORT_COLOR.magenta
                    "T" => $REPORT_COLOR.blue
                    "U" => $REPORT_COLOR.red
                    "?" => $REPORT_COLOR.darkGray
                    _ => $REPORT_COLOR.darkGray
                })
            }
        }
        def printBranchHeading [branch: string] {
            print $"($REPORT_INDENT.branch)($REPORT_COLOR.branch)($branch):($REPORT_COLOR.reset)"
        }
        def printRepoHeading [repo: string] {
            print $"($REPORT_COLOR.repo)($repo | path basename)($REPORT_COLOR.reset)"
        }
        def printSectionHeading [direction: string] {
            let arrow = if $direction == "remote" { glyph "↓" "v" } else { glyph "↑" "^" }
            print $"($REPORT_INDENT.section)($REPORT_COLOR.section)($arrow) ($direction)($REPORT_COLOR.reset)"
        }
        def printFileLine [indent: string, letter: string, path: string, date: string] {
            let mark = (changeMark $letter)
            let dateText = if ($date | is-empty) { "" } else { $"  ($REPORT_COLOR.darkGray)($date)($REPORT_COLOR.reset)" }
            print $"($indent)($mark.color)($mark.text)  ($path)($REPORT_COLOR.reset)($dateText)"
        }
        def printLocalFiles [files: list<record>] {
            for file in $files {
                printFileLine $REPORT_INDENT.item $file.letter $file.path $file.date
            }
        }
        def printCommitFiles [repo: string, hash: string] {
            let rows = (gitSafe $repo diff-tree --no-commit-id -r --name-status -M --root $hash | complete | get stdout | lines)
            for row in $rows {
                let parts = ($row | split row (char tab))
                let status = ($parts | first)
                let letter = ($status | str substring 0..0)
                let path = if $letter in [ "R" "C" ] {
                    $"($parts | get 1) -> ($parts | get 2)"
                } else {
                    $parts | get 1
                }
                printFileLine $REPORT_INDENT.detail $letter $path ""
            }
        }
        def printHistoryCommit [repo: string, letter: string, commit: record] {
            let mark = (changeMark $letter)
            let hash = ($commit.hash | str substring 0..7)
            print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($hash)($REPORT_COLOR.reset) ($mark.color)($commit.subject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($commit.date)($REPORT_COLOR.reset)"
            printCommitFiles $repo $commit.hash
        }
        def printRewrittenCommit [letter: string, event: record] {
            let oldHash = ($event.oldHash | str substring 0..7)
            let newHash = ($event.newHash | str substring 0..7)
            if $letter == "R" {
                let mark = (changeMark $letter)
                print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($oldHash)($REPORT_COLOR.reset) ($mark.color)($event.oldSubject) -> ($REPORT_COLOR.magenta)($newHash)($REPORT_COLOR.reset) ($mark.color)($event.newSubject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($event.date)($REPORT_COLOR.reset)"
            } else {
                print $"($REPORT_INDENT.item)   ($REPORT_COLOR.magenta)($oldHash)($REPORT_COLOR.reset) ($event.oldSubject) -> ($REPORT_COLOR.magenta)($newHash)($REPORT_COLOR.reset) ($event.newSubject)  ($REPORT_COLOR.darkGray)($event.date)($REPORT_COLOR.reset)"
            }
        }
        def printRemoteDiff [repo: string, diff: record, inputs: list<record>, --quiet] {
            let events = ($diff.events? | default [])
            if ($events | is-empty) and ($inputs | is-empty) { return }
            printSectionHeading "remote"
            for event in $events {
                if $event.kind == "added" {
                    printHistoryCommit $repo "A" $event.commit
                } else if $event.kind == "renamed" {
                    printRewrittenCommit "R" $event
                } else if $event.kind == "rehashed" {
                    printRewrittenCommit "M" $event
                }
            }
            printInputChanges $repo $inputs --quiet=$quiet
        }
        def printLocalDiff [repo: string, files: list<record>, commits: list<record>, inputs: list<record>, --quiet] {
            if ($files | is-empty) and ($commits | is-empty) and ($inputs | is-empty) { return }
            printSectionHeading "local"
            printLocalFiles $files
            for commit in $commits {
                printHistoryCommit $repo "A" $commit
            }
            printInputChanges $repo $inputs --quiet=$quiet
        }
        def printCatastrophe [repo: string, diff: record] {
            print -e $"($REPORT_INDENT.item)($REPORT_COLOR.redBold)CATASTROPHE: ($diff.deleted | length) commits deleted, branch skipped($REPORT_COLOR.reset)"
            for commit in $diff.deleted {
                printHistoryCommit $repo "D" $commit
            }
            for commit in $diff.added {
                printHistoryCommit $repo "A" $commit
            }
        }
        def catastropheMarkerPathAt [root: string, repo: string, branch: string] {
            let repoName = ($repo | path basename)
            let safeBranch = ($branch | str replace --all "/" "_")
            [$root $"($repoName)-($safeBranch)"] | path join
        }
        def catastropheMarkerPath [repo: string, branch: string] {
            catastropheMarkerPathAt "/run/nixos-config-reported" $repo $branch
        }
        def printQuietCatastropheAt [repo: string, branch: string, result: record, root: string] {
            let marker = (catastropheMarkerPathAt $root $repo $branch)
            printBranchHeading $branch
            if ($marker | path exists) {
                let previous = (open --raw $marker | str trim)
                if $previous == $result.candidate {
                    let short = (gitSafe $repo rev-parse --short $result.candidate | complete | get stdout | str trim)
                    let unresolved = ("CATASTROPHE still unresolved (origin " + $short + ")")
                    print -e ($REPORT_INDENT.section + $REPORT_COLOR.redBold + $unresolved + $REPORT_COLOR.reset)
                    return
                }
            }
            printSectionHeading "remote"
            printCatastrophe $repo $result.diff
            printInputChanges $repo ($result.remoteInputs? | default []) --quiet
            printLocalDiff $repo ($result.localFiles? | default []) [] ($result.localInputs? | default []) --quiet
            mkdir ($marker | path dirname)
            $result.candidate | save --force $marker
        }
        def printQuietCatastrophe [repo: string, branch: string, result: record] {
            printQuietCatastropheAt $repo $branch $result "/run/nixos-config-reported"
        }
        def clearCatastropheMarker [repo: string, branch: string] {
            let marker = (catastropheMarkerPath $repo $branch)
            if ($marker | path exists) {
                rm $marker
            }
        }
        def branchHasReport [result: record] {
            if $result.state in [ "catastrophe" "both-moved" "conflict" ] { return true }
            let diff = $result.diff? | default null
            let localFiles = $result.localFiles? | default []
            let pushed = $result.pushed? | default []
            let localInputs = $result.localInputs? | default []
            let remoteInputs = $result.remoteInputs? | default []
            let remoteEvents = if $diff == null { [] } else { $diff.events? | default [] }
            let rewritten = if $result.state == "rewritten" {
                if $diff == null { false } else {
                    ($diff.deleted | is-not-empty) or ($diff.added | is-not-empty)
                }
            } else { false }
            ($result.state in [ "catastrophe" "both-moved" "conflict" ]) or ($localFiles | is-not-empty) or ($pushed | is-not-empty) or ($localInputs | is-not-empty) or ($remoteInputs | is-not-empty) or ($remoteEvents | is-not-empty) or $rewritten
        }
        def printBranchResult [repo: string, branch: string, result: record, --quiet] {
            if $result.state == "catastrophe" {
                printBranchHeading $branch
                let direction = $result.direction? | default "remote"
                let localInputs = $result.localInputs? | default []
                let remoteInputs = $result.remoteInputs? | default []
                if $direction == "remote" {
                    printSectionHeading "remote"
                    printCatastrophe $repo $result.diff
                    printInputChanges $repo $remoteInputs --quiet=$quiet
                    printLocalDiff $repo ($result.localFiles? | default []) [] $localInputs --quiet=$quiet
                } else {
                    let remoteDiff = $result.remoteDiff? | default null
                    if $remoteDiff != null and not $remoteDiff.kept {
                        printSectionHeading "remote"
                        for commit in $remoteDiff.deleted { printHistoryCommit $repo "D" $commit }
                        for commit in $remoteDiff.added { printHistoryCommit $repo "A" $commit }
                        printInputChanges $repo $remoteInputs --quiet=$quiet
                    } else {
                        printRemoteDiff $repo ($remoteDiff | default { events: [] }) $remoteInputs --quiet=$quiet
                    }
                    printLocalDiff $repo ($result.localFiles? | default []) [] $localInputs --quiet=$quiet
                    if ($result.localFiles? | default [] | is-empty) and ($localInputs | is-empty) {
                        printSectionHeading "local"
                    }
                    printCatastrophe $repo $result.diff
                }
                return true
            }
            if $result.state == "both-moved" {
                printBranchHeading $branch
                print $"($REPORT_INDENT.section)($REPORT_COLOR.yellow)(glyph "→" ">") both local and origin have new commits, switch to it to sync($REPORT_COLOR.reset)"
                return true
            }
            if $result.state == "conflict" {
                printBranchHeading $branch
                let files = $result.conflictFiles? | default []
                let suffix = if ($files | is-empty) { "" } else { ": " + ($files | str join ", ") }
                print $"($REPORT_INDENT.section)($REPORT_COLOR.yellow)conflict, branch skipped($suffix)($REPORT_COLOR.reset)"
                return true
            }
            let diff = $result.diff?
            let localFiles = $result.localFiles? | default []
            let pushed = $result.pushed? | default []
            let localInputs = $result.localInputs? | default []
            let remoteInputs = $result.remoteInputs? | default ($diff.remoteInputs? | default [])
            let remoteChanged = if $result.state != "local-ahead" and $diff != null {
                (($diff.events? | default []) | is-not-empty) or ($remoteInputs | is-not-empty)
            } else { false }
            let rewritten = if $result.state == "rewritten" {
                if $diff == null { false } else {
                    ($diff.deleted | is-not-empty) or ($diff.added | is-not-empty)
                }
            } else { false }
            if not $remoteChanged and not $rewritten and ($localFiles | is-empty) and ($pushed | is-empty) and ($localInputs | is-empty) { return false }
            printBranchHeading $branch
            if $result.state == "rewritten" {
                printSectionHeading "remote"
                for commit in $diff.deleted { printHistoryCommit $repo "D" $commit }
                for commit in $diff.added { printHistoryCommit $repo "A" $commit }
                printInputChanges $repo $remoteInputs --quiet=$quiet
            } else if $remoteChanged {
                printRemoteDiff $repo ($diff | default { events: [] }) $remoteInputs --quiet=$quiet
            }
            printLocalDiff $repo $localFiles $pushed $localInputs --quiet=$quiet
            true
        }
        def printRepoResults [repo: string, results: list<record>, --quiet] {
            let visible = ($results | where { |entry| branchHasReport $entry.result })
            if ($visible | is-empty) { return false }
            printRepoHeading $repo
            for entry in $visible {
                if $quiet and $entry.result.state == "catastrophe" and ($entry.result.direction? | default "remote") == "remote" {
                    printQuietCatastrophe $repo $entry.branch $entry.result
                } else {
                    printBranchResult $repo $entry.branch $entry.result --quiet=$quiet
                }
            }
            true
        }
        def printEverythingUpToDate [] {
            print $"($REPORT_COLOR.darkGray)everything up to date($REPORT_COLOR.reset)"
        }
        # only DNS/connectivity failures count as offline; auth and other errors are real errors
        def isNetworkError [stderr: string] {
            [ "Could not resolve" "Temporary failure in name resolution" "Network is unreachable"
              "No route to host" "Connection timed out" "Connection refused" ]
            | any { |pat| $stderr | str contains $pat }
        }
        def commitRecords [records: list<record>] {
            $records | each { |entry| { hash: $entry.hash, subject: $entry.subject, date: $entry.date } }
        }
        def historyRange [repo: string, range: string] {
            let result = (gitSafe $repo log --reverse --first-parent '--format=%H%x1f%T%x1f%s%x1f%ad%x1f%P' '--date=format:%Y-%m-%d %H:%M:%S' $range | complete)
            if $result.exit_code != 0 { error make { msg: $"($repo): history read failed\n($result.stderr)" } }
            $result.stdout | lines | each { |line|
                let fields = ($line | split row "\u{1f}")
                {
                    hash: ($fields | get 0)
                    tree: ($fields | get 1)
                    subject: ($fields | get 2)
                    date: ($fields | get 3)
                    parents: ($fields | get 4)
                }
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
                    if $event.kind == "added" { $event.commit } else {
                        {
                            hash: $event.newHash
                            subject: $event.newSubject
                            date: $event.date
                        }
                    }
                }
            }
        }
        # checks first-parent trees, allowing message-only renames but no deleted or changed commits
        def historyDiff [repo: string, accepted: string, candidate: string] {
            if (gitSafe $repo merge-base --is-ancestor $accepted $candidate | complete | get exit_code) == 0 {
                let added = (commitRecords (historyRange $repo $"($accepted)..($candidate)"))
                return {
                    kept: true
                    deleted: []
                    added: $added
                    events: ($added | each { |commit| { kind: "added", commit: $commit } })
                }
            }

            let mergeBase = (gitSafe $repo merge-base $accepted $candidate | complete)
            let base = if $mergeBase.exit_code == 0 { $mergeBase.stdout | str trim } else { null }
            let aRange = if $base == null { $accepted } else { $"($base)..($accepted)" }
            let bRange = if $base == null { $candidate } else { $"($base)..($candidate)" }
            let aRecords = (historyRange $repo $aRange)
            let bRecords = (historyRange $repo $bRange)
            let aHashes = ($aRecords | get hash)
            let bHashes = ($bRecords | get hash)
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
                    let event = {
                        kind: (if $old.subject != $new.subject { "renamed" } else { "rehashed" })
                        oldHash: $old.hash
                        newHash: $new.hash
                        oldSubject: $old.subject
                        newSubject: $new.subject
                        date: $new.date
                    }
                    $rewriteEvents = ($rewriteEvents | append $event)
                }
            }
            if $mismatch < 0 and ($bRecords | length) < ($aRecords | length) {
                $mismatch = $pairedCount
            }
            let kept = $mismatch < 0 and ($aMerges | is-empty) and ($bMerges | is-empty)
            let start = if $mismatch < 0 { 0 } else { $mismatch }
            let deleted = if $kept { [] } else { commitRecords ($aRecords | skip $start) }
            let added = if $kept { commitRecords ($bRecords | skip ($aRecords | length)) } else { commitRecords ($bRecords | skip $start) }
            let events = if $kept {
                $rewriteEvents ++ ($added | each { |commit| { kind: "added", commit: $commit } })
            } else {
                []
            }
            {
                kept: $kept
                deleted: $deleted
                added: $added
                events: $events
            }
        }
        # shows what a rewritten origin history drops and brings (git's own colours, only the headline is red) and asks; true = take it
        def confirmRewrite [repo: string, accepted: string, candidate: string] {
            let sudoUser = ($env.SUDO_USER? | default "")
            if not (is-admin) or ($sudoUser | is-empty) or not (is-terminal --stdin) {
                return false
            }
            let diff = (historyDiff $repo $accepted $candidate)
            printRepoHeading $repo
            printBranchHeading (repoBranch $repo)
            printSectionHeading "remote"
            printCatastrophe $repo $diff
            (input "take origin's history? type yes: " | str trim) == "yes"
        }
        def confirmLocalRewrite [repo: string, accepted: string, candidate: string] {
            let sudoUser = ($env.SUDO_USER? | default "")
            if not (is-admin) or ($sudoUser | is-empty) or not (is-terminal --stdin) {
                return false
            }
            let diff = (historyDiff $repo $accepted $candidate)
            printRepoHeading $repo
            printBranchHeading (repoBranch $repo)
            printSectionHeading "local"
            printCatastrophe $repo $diff
            (input "push local history? type yes: " | str trim) == "yes"
        }
        # fetches origin's <branch> (the one checked out here) into origin/candidate and rebases local work on it
        # (uncommitted changes ride along via --autostash). origin/<branch> moves only when historyDiff keeps the
        # accepted history: a captured host force-pushing a gutted repo is refused
        # here, so this host keeps its copy and keeps reporting until someone looks. origin/<branch> is also the
        # lease repoPush checks against, so nothing is pushed on top of a refused history either. --on-rewrite { |accepted, candidate| -> bool } gets to
        # decide instead of refusing (cfg sync passes confirmRewrite); nothing automatic may pass it.
        # returns the catastrophe record when origin history is not kept; with --pause skips a fresh fetch
        def repoSync [repo: string, --pause, --on-rewrite: closure] {
            let gitDir = (checkRepoState $repo)
            let branch = (repoBranch $repo)
            let fetchHead = $"($repo)/($gitDir)/FETCH_HEAD"
            if $pause and ($fetchHead | path exists) and (((date now) - (ls -D $fetchHead | get 0 | get modified)) < 3min) {
                return { online: true, changed: false }
            }
            # fetch fails on network errors, rebase fails on conflicts; separate calls tell the two apart
            # --refmap= stops git from also updating origin/<branch> "opportunistically" through the configured refspec
            let fetch = (fetchCandidate $repo $branch)
            if not $fetch.online { return { online: false, changed: false, state: "offline" } }
            if $fetch.state == "missing" {  # branch made here, not on origin yet; repoPush creates it
                return { online: true, changed: false, state: "origin-missing" }
            }
            let candidate = $fetch.candidate
            let accepted = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete)  # missing before the first sync of a fresh clone or a new branch
            let accepted = if $accepted.exit_code == 0 { $accepted.stdout | str trim } else { null }
            let remoteInputs = (remoteFlakeInputs $repo ($accepted | default "") $candidate)
            let diff = if $accepted == null { null } else { historyDiff $repo $accepted $candidate }
            mut rewriteAccepted = false
            if $accepted != null and not $diff.kept {
                if $on_rewrite != null {
                    if not (do $on_rewrite $accepted $candidate) {
                        return { online: true, changed: false, state: "catastrophe", direction: "remote", branch: $branch, diff: $diff, accepted: $accepted, candidate: $candidate, localFiles: (worktreeFiles $repo), remoteInputs: $remoteInputs }
                    }
                    $rewriteAccepted = true
                } else {
                    return { online: true, changed: false, state: "catastrophe", direction: "remote", branch: $branch, diff: $diff, accepted: $accepted, candidate: $candidate, localFiles: (worktreeFiles $repo), remoteInputs: $remoteInputs }
                }
            }
            gitSafe $repo update-ref $"refs/remotes/origin/($branch)" $candidate
            let oldHead = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)  # hash of the current commit
            # files changed only by mtime make --autostash bail out; refresh the index stat info first (nonzero when real changes exist)
            try { gitSafe $repo update-index -q --really-refresh } catch { }
            let stashCount = (gitSafe $repo stash list | complete | get stdout | lines | length)  # baseline for the autostash check below
            # --onto: replay only what was committed here after the last accepted origin state; commits a
            # taken rewrite removed are not resurrected (plain `rebase origin/<branch>` would replay them too)
            let rebase = if $accepted != null {
                gitSafe $repo rebase --autostash --quiet --onto $candidate $accepted | complete
            } else {
                gitSafe $repo rebase --autostash --quiet $candidate | complete
            }
            if $rebase.exit_code != 0 {
                if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) {
                    gitSafe $repo rebase --abort
                }
                error make { msg: $"($repo): rebase failed\n($rebase.stderr)" }
            }
            # --autostash keeps the stash entry (and drops the changes from the worktree) when it can't re-apply cleanly
            if ((gitSafe $repo stash list | complete | get stdout | lines | length) > $stashCount) or ($rebase.stderr | str contains "safe in the stash") {
                error make { msg: $"($repo): local changes were kept in the stash, apply it manually" }
            }
            {
                online: true
                changed: ((gitSafe $repo rev-parse HEAD | complete | get stdout | str trim) != $oldHead)
                state: (if $rewriteAccepted { "rewritten" } else { "updated" })
                branch: $branch
                diff: $diff
                candidate: $candidate
                remoteInputs: $remoteInputs
            }
        }
        # pushes HEAD to origin/<branch> with --force-with-lease; on rejection syncs once and retries
        # --report returns a structured result for the branch output
        def repoPush [repo: string, --no-retry, --report, --on-rewrite: closure] {
            let branch = (repoBranch $repo)
            let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)  # remote tip (empty for a branch origin lacks); local == remote means nothing to push
            if $local == $remote {
                return (if $report { { online: true, state: "up-to-date", branch: $branch } } else { true })
            }
            let pushState = (pushHistoryState $repo $remote $local $on_rewrite)
            let diff = $pushState.diff
            if $pushState.catastrophe {
                if $report {
                    return { online: true, state: "catastrophe", direction: "local", branch: $branch, diff: $diff, accepted: $remote, candidate: $local, localFiles: (worktreeFiles $repo) }
                }
                error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
            }
            if not $report {
                gitSafe $repo --no-pager log -1 --oneline '--format=%C(magenta)%h%C(auto)%d %s'
            }
            let start = (date now)
            mut pushed = (pushCandidate $repo $branch "HEAD" $remote)
            if $pushed.state == "offline" {
                return (if $report { { online: false, state: "offline", branch: $branch } } else { false })
            }
            if $pushed.state == "rejected" {
                if $no_retry {
                    error make { msg: $"($repo): push rejected\n($pushed.stderr)" }
                }
                # remote moved between our fetch and push: sync again and retry once
                let sync = (repoSync $repo --on-rewrite=$on_rewrite)
                if $sync.state? == "catastrophe" {
                    if $report { return $sync }
                    error make { msg: $"($repo): history on origin was rewritten, local copy kept" }
                }
                let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
                let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
                let pushState = (pushHistoryState $repo $remote $local $on_rewrite)
                let diff = $pushState.diff
                if $pushState.catastrophe {
                    if $report {
                        return { online: true, state: "catastrophe", direction: "local", branch: $branch, diff: $diff, accepted: $remote, candidate: $local, localFiles: (worktreeFiles $repo) }
                    }
                    error make { msg: $"($repo): ($branch): local branch changed or dropped commits that are on origin, not pushed" }
                }
                $pushed = (pushCandidate $repo $branch "HEAD" $remote)
                if $pushed.state == "offline" {
                    return (if $report { { online: false, state: "offline", branch: $branch } } else { false })
                }
                if $pushed.state == "rejected" {
                    error make { msg: $"($repo): push failed\n($pushed.stderr)" }
                }
            }
            if not $report {
                print $"($REPORT_COLOR.greenBold)Successful push in ((date now) - $start)($REPORT_COLOR.reset)"
            }
            if $report { { online: true, state: "pushed", branch: $branch } } else { true }
        }
        # syncs one local branch without checking it out
        def repoSyncBranch [repo: string, branch: string, action: string, --on-rewrite: closure, --on-local-rewrite: closure] {
            checkRepoState $repo
            let local = (gitSafe $repo rev-parse $"refs/heads/($branch)" | complete | get stdout | str trim)
            let acceptedResult = (gitSafe $repo rev-parse -q --verify $"refs/remotes/origin/($branch)" | complete)
            let accepted = if $acceptedResult.exit_code == 0 { $acceptedResult.stdout | str trim } else { null }
            let fetch = (fetchCandidate $repo $branch)
            if not $fetch.online {
                return { online: false, state: "offline", branch: $branch }
            }
            if $fetch.state == "missing" {
                    if $action == "pull" {
                        return { online: true, state: "origin-missing", branch: $branch }
                    }
                    let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" "")
                    if $pushed.state == "offline" { return { online: false, state: "offline", branch: $branch } }
                    if $pushed.state != "pushed" {
                        error make { msg: $"($repo): push of new branch ($branch) failed\n($pushed.stderr)" }
                    }
                    updateRemoteBranchRef $repo $branch $local
                    return { online: true, state: "pushed", branch: $branch, pushed: (commitsToPush $repo "" $local) }
                }
            let candidate = $fetch.candidate
            let base = if $accepted == null { $candidate } else { $accepted }
            let remoteInputs = (remoteFlakeInputs $repo ($accepted | default "") $candidate)
            if $local == $base {
                let diff = (historyDiff $repo $base $candidate)
                mut rewriteAccepted = false
                if not $diff.kept {
                    if $on_rewrite == null or not (do $on_rewrite $base $candidate) {
                        return { online: true, state: "catastrophe", direction: "remote", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate, remoteInputs: $remoteInputs }
                    }
                    $rewriteAccepted = true
                }
                if $local != $candidate {
                    gitSafe $repo update-ref $"refs/heads/($branch)" $candidate $local
                }
                updateRemoteBranchRef $repo $branch $candidate
                return { online: true, state: (if $rewriteAccepted { "rewritten" } else if $local == $candidate { "up-to-date" } else { "updated" }), branch: $branch, diff: $diff, accepted: $base, candidate: $candidate, remoteInputs: $remoteInputs }
            }
            if $candidate == $base {
                let diff = (historyDiff $repo $base $local)
                if not $diff.kept {
                    if $action == "sync" and $on_local_rewrite != null and (do $on_local_rewrite $base $local) {
                        let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $base)
                        if $pushed.state == "offline" { return { online: false, state: "offline", branch: $branch } }
                        if $pushed.state != "pushed" {
                            error make { msg: $"($repo): push of rewritten branch ($branch) failed\n($pushed.stderr)" }
                        }
                        updateRemoteBranchRef $repo $branch $local
                        return { online: true, state: "pushed", branch: $branch, diff: $diff, accepted: $base, candidate: $local, pushed: (commitsToPush $repo $base $local) }
                    }
                    return { online: true, state: "catastrophe", direction: "local", branch: $branch, diff: $diff, accepted: $base, candidate: $local, remoteInputs: $remoteInputs }
                }
                if $action == "pull" {
                    if $accepted == null { updateRemoteBranchRef $repo $branch $candidate }
                    return { online: true, state: "local-ahead", branch: $branch, diff: $diff, accepted: $base, candidate: $candidate, remoteInputs: $remoteInputs }
                }
                let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $base)
                if $pushed.state == "offline" { return { online: false, state: "offline", branch: $branch } }
                if $pushed.state != "pushed" {
                    error make { msg: $"($repo): push of branch ($branch) failed\n($pushed.stderr)" }
                }
                updateRemoteBranchRef $repo $branch $local
                return { online: true, state: "pushed", branch: $branch, diff: null, accepted: $base, candidate: $local, pushed: (commitsToPush $repo $base $local), remoteInputs: $remoteInputs }
            }
            let remoteDiff = (historyDiff $repo $base $candidate)
            let localDiff = (historyDiff $repo $base $local)
            if not $remoteDiff.kept {
                if $on_rewrite == null or not (do $on_rewrite $base $candidate) {
                    return { online: true, state: "catastrophe", direction: "remote", branch: $branch, diff: $remoteDiff, accepted: $base, candidate: $candidate, remoteInputs: $remoteInputs }
                }
            }
            if not $localDiff.kept {
                return { online: true, state: "catastrophe", direction: "local", branch: $branch, diff: $localDiff, accepted: $base, candidate: $local, remoteInputs: $remoteInputs }
            }
            let replay = (gitSafe $repo replay --onto $candidate $"($base)..refs/heads/($branch)" --ref-action=print | complete)
            if $replay.exit_code != 0 {
                let conflicts = (gitSafe $repo diff --name-only --diff-filter=U | complete | get stdout | lines)
                return { online: true, state: "conflict", branch: $branch, conflictFiles: $conflicts }
            }
            if not ($replay.stdout | str trim | is-empty) {
                $replay.stdout | gitSafe $repo update-ref --stdin
            }
            updateRemoteBranchRef $repo $branch $candidate
            let replayed = (gitSafe $repo rev-parse $"refs/heads/($branch)" | complete | get stdout | str trim)
            if $action in [ "push" "sync" ] and $replayed != $candidate {
                let pushed = (pushCandidate $repo $branch $"refs/heads/($branch)" $candidate)
                if $pushed.state == "offline" {
                    return { online: false, state: "offline", branch: $branch, diff: $remoteDiff, pushed: (commitsToPush $repo $candidate $replayed) }
                }
                if $pushed.state != "pushed" {
                    error make { msg: $"($repo): push of replayed branch ($branch) failed\n($pushed.stderr)" }
                }
                updateRemoteBranchRef $repo $branch $replayed
                return { online: true, state: "pushed", branch: $branch, diff: $remoteDiff, accepted: $base, candidate: $replayed, pushed: (commitsToPush $repo $candidate $replayed) }
            }
            { online: true, state: "updated", branch: $branch, diff: $remoteDiff, accepted: $base, candidate: $candidate, remoteInputs: $remoteInputs }
        }
        # revision of the common input recorded in the repo's flake.lock (null if absent)
        def lockedRev [repo: string] {
            try {
                open $"($repo)/flake.lock" | from json | get nodes.common.locked.rev
            } catch {
                null
            }
        }
        # re-locks the common input inside a host flake; nix output is shown only on failure
        def updateCommonLock [repo: string] {
            cd $repo
            let res = (^/run/current-system/sw/bin/nix flake update --refresh common | complete)
            if $res.exit_code != 0 {
                    print $"($res.stdout)\n($REPORT_COLOR.red)($res.stderr)($REPORT_COLOR.reset)"
                error make { msg: $"($repo): nix flake update common failed" }
            }
        }
        # commits selected worktree changes and returns their report rows
        def inputSource [original: record] {
            let url = ($original.url? | default "")
            let type = ($original.type? | default "")
            if not ($url | is-empty) { return $url }
            if $type == "github" {
                let ref = ($original.ref? | default "")
                let source = $"github:($original.owner? | default "?")/($original.repo? | default "?")"
                return (if ($ref | is-empty) { $source } else { $"($source)?ref=($ref)" })
            }
            let id = ($original.id? | default "")
            if not ($id | is-empty) { $"($type):($id)" } else { $type }
        }
        def resolveFollow [nodes: record, root: string, segments: list<string>] {
            mut current = $root
            for segment in $segments {
                let node = ($nodes | get --optional $current)
                if $node == null { return null }
                let input = (($node.inputs? | default {}) | get --optional $segment)
                if $input == null { return null }
                if ($input | describe | str starts-with "list") {
                    $current = (resolveFollow $nodes $root $input)
                } else {
                    $current = $input
                }
            }
            $current
        }
        def walkLockInput [nodes: record, root: string, input: any, path: string, ancestors: list<string>] {
            if ($input | describe | str starts-with "list") {
                let follows = ($input | str join "/")
                let target = (resolveFollow $nodes $root $input)
                if $target == null {
                    return [{
                        path: $path
                        follows: $follows
                        original: ""
                        rev: ""
                        lastModified: null
                        date: ""
                        narHash: ""
                    }]
                }
                walkLockNode $nodes $root $target $path $follows $ancestors
            } else {
                walkLockNode $nodes $root $input $path "" $ancestors
            }
        }
        def walkLockNode [nodes: record, root: string, nodeId: string, path: string, follows: string, ancestors: list<string>] {
            let node = ($nodes | get --optional $nodeId)
            if $node == null {
                return [{
                    path: $path
                    follows: $follows
                    original: ""
                    rev: ""
                    lastModified: null
                    date: ""
                    narHash: ""
                }]
            }
            let locked = ($node.locked? | default {})
            let lastModified = ($locked.lastModified? | default null)
            let date = if $lastModified == null { "" } else {
                try { $lastModified * 1_000_000_000 | into datetime | format date '%Y-%m-%d %H:%M:%S' } catch { "" }
            }
            let entry = {
                path: $path
                follows: $follows
                original: (inputSource ($node.original? | default {}))
                rev: ($locked.rev? | default "")
                lastModified: $lastModified
                date: $date
                narHash: ($locked.narHash? | default "")
            }
            mut result = [ $entry ]
            let nextAncestors = ($ancestors | append $nodeId)
            if $nodeId not-in $ancestors {
                let inputs = ($node.inputs? | default {})
                for name in ($inputs | columns) {
                    let childPath = $"($path)/($name)"
                    $result = ($result ++ (walkLockInput $nodes $root ($inputs | get $name) $childPath $nextAncestors))
                }
            }
            $result
        }
        def flakeLockInputs [text: string] {
            try {
                let lock = ($text | from json)
                let nodes = $lock.nodes
                let root = $lock.root
                let rootInputs = (($nodes | get $root).inputs? | default {})
                mut result = []
                for name in ($rootInputs | columns) {
                    $result = ($result ++ (walkLockInput $nodes $root ($rootInputs | get $name) $name [ $root ]))
                }
                $result | sort-by path
            } catch { [] }
        }
        def compareFlakeInputs [before: list<record>, after: list<record>] {
            let beforePaths = ($before | get path)
            let afterPaths = ($after | get path)
            mut changes = []
            for current in $after {
                if $current.path not-in $beforePaths {
                    $changes = ($changes | append { kind: "added", item: $current })
                    continue
                }
                let old = ($before | where { |entry| $entry.path == $current.path } | first)
                let kind = if ($old.original != $current.original) or ($old.follows != $current.follows) {
                    "source"
                } else if ($old.rev == $current.rev) and ($old.narHash != $current.narHash) {
                    "narHash"
                } else if $old.rev != $current.rev {
                    if ($old.lastModified != null) and ($current.lastModified != null) and ($current.lastModified < $old.lastModified) { "downgrade" } else { "updated" }
                } else {
                    ""
                }
                if not ($kind | is-empty) {
                    $changes = ($changes | append { kind: $kind, old: $old, item: $current })
                }
            }
            for old in $before {
                if $old.path not-in $afterPaths {
                    $changes = ($changes | append { kind: "removed", item: $old })
                }
            }
            $changes | sort-by { |change| $change.item.path }
        }
        def lockText [repo: string, source: string] {
            if $source == "worktree" {
                try { open --raw $"($repo)/flake.lock" } catch { "" }
            } else if $source == "index" {
                let result = (gitSafe $repo show :flake.lock | complete)
                if $result.exit_code == 0 { $result.stdout } else { "" }
            } else {
                let result = (gitSafe $repo show $"($source):flake.lock" | complete)
                if $result.exit_code == 0 { $result.stdout } else { "" }
            }
        }
        def localFlakeInputs [repo: string, source: string] {
            compareFlakeInputs (flakeLockInputs (lockText $repo "HEAD")) (flakeLockInputs (lockText $repo $source))
        }
        def remoteFlakeInputs [repo: string, accepted: string, candidate: string] {
            let before = if ($accepted | is-empty) { [] } else { flakeLockInputs (lockText $repo $accepted) }
            compareFlakeInputs $before (flakeLockInputs (lockText $repo $candidate))
        }
        def printInputChanges [repo: string, changes: list<record>, --quiet] {
            if ($changes | is-empty) { return }
            print $"($REPORT_INDENT.item)($REPORT_COLOR.section)inputs($REPORT_COLOR.reset)"
            for change in $changes {
                let path = $change.item.path
                let indent = $REPORT_INDENT.detail
                if $change.kind == "added" {
                    let item = $change.item
                    let rev = if ($item.rev | is-empty) { "" } else { $item.rev | str substring 0..7 }
                    print $"($indent)($REPORT_COLOR.greenBold)A  ($path)  ($item.original)  ($rev)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($item.date)($REPORT_COLOR.reset)"
                    if not ($item.follows | is-empty) {
                        print $"($REPORT_INDENT.detail)   follows: ($item.follows)"
                    }
                } else if $change.kind == "removed" {
                    print $"($indent)($REPORT_COLOR.redBold)D  ($path)($REPORT_COLOR.reset)"
                } else if $change.kind == "updated" or $change.kind == "downgrade" {
                    let oldRev = if ($change.old.rev | is-empty) { "" } else { $change.old.rev | str substring 0..7 }
                    let newRev = if ($change.item.rev | is-empty) { "" } else { $change.item.rev | str substring 0..7 }
                    let color = if $change.kind == "updated" { $REPORT_COLOR.yellow } else { $REPORT_COLOR.magentaBold }
                    let mark = if $change.kind == "updated" { "M" } else { "v" }
                    print $"($indent)($color)($mark)  ($path)  ($oldRev) -> ($newRev)  ($REPORT_COLOR.darkGray)($change.old.date) -> ($change.item.date)($REPORT_COLOR.reset)"
                } else if $change.kind == "source" {
                    let color = (sourceChangeColor)
                    let oldSource = if $change.old.follows != $change.item.follows {
                        $"follows: (if ($change.old.follows | is-empty) { "none" } else { $change.old.follows })"
                    } else { $change.old.original }
                    let newSource = if $change.old.follows != $change.item.follows {
                        (if ($change.item.follows | is-empty) { "none" } else { $change.item.follows })
                    } else { $change.item.original }
                    print $"($indent)($color)S  ($path)  ($oldSource) -> ($newSource)($REPORT_COLOR.reset)"
                } else if $change.kind == "narHash" {
                    let message = $"($path): narHash changed for the same rev"
                    print $"($indent)($REPORT_COLOR.redBold)!  ($message)($REPORT_COLOR.reset)"
                    reportProblem $repo $message --quiet=$quiet
                }
            }
        }
        def worktreeFiles [repo: string, --unstaged-only] {
            let entries = (gitSafe $repo status --porcelain=v1 -z | complete | get stdout | split row (char nul) | where { |entry| $entry != "" })
            mut files = []
            mut i = 0
            loop {
                if $i >= ($entries | length) { break }
                let line = ($entries | get $i)
                let status = ($line | str substring 0..1)
                let marks = { A: "A", M: "M", D: "D", R: "R", C: "C", T: "T", U: "U" }
                let indexStatus = ($status | str substring 0..0)
                let worktreeStatus = ($status | str substring 1..1)
                let letter = if $status == "??" { "?" } else {
            ($marks | get --optional $indexStatus | default ($marks | get --optional $worktreeStatus | default "?"))
                }
                let path = ($line | str substring 3..)
                let oldPath = if $letter in [ "R" "C" ] {
                    $i = $i + 1
                    $entries | get $i
                } else { null }
                let displayPath = if $oldPath == null { $path } else { $"($oldPath) -> ($path)" }
                let fullPath = [$repo $path] | path join
                let date = if ($fullPath | path exists) {
                    try { ls -D $fullPath | get 0 | get modified | format date '%Y-%m-%d %H:%M:%S' } catch { "?" }
                } else { "?" }
                let unstaged = ($status == "??") or (($status | str substring 1..1) != " ")
                if not $unstaged_only or $unstaged {
                    $files = ($files | append { letter: $letter, path: $displayPath, date: $date })
                }
                $i = $i + 1
            }
            $files
        }
        def commitRepo [repo: string, message: string, --no-add] {
            if not $no_add { gitSafe $repo add . }
            let files = if $no_add { worktreeFiles $repo --unstaged-only } else { worktreeFiles $repo }
            let inputs = (localFlakeInputs $repo "index")
            let staged = (gitSafe $repo diff --cached --name-only | complete | get stdout)
            let committed = not ($staged | is-empty)
            if $committed {
                silent { gitSafe $repo commit -m $message }
            }
            { files: $files, committed: $committed, inputs: $inputs }
        }
        def commitAndPush [repo: string, message: string, remoteDiff?: record, remoteInputs?: list<record>, --no-add] {
            let changes = (commitRepo $repo $message --no-add=$no_add)
            let branch = (repoBranch $repo)
            let remote = (gitSafe $repo rev-parse -q --verify $"origin/($branch)" | complete | get stdout | str trim)
            let local = (gitSafe $repo rev-parse HEAD | complete | get stdout | str trim)
            let commits = (commitsToPush $repo $remote $local)
            let pushed = (repoPush $repo --report)
            if $pushed.state == "catastrophe" {
                let result = (($pushed | upsert localFiles $changes.files) | upsert remoteDiff $remoteDiff)
                if (branchHasReport $result) { printRepoHeading $repo }
                return (printBranchResult $repo $branch $result)
            }
            let pending = if $pushed.state == "pushed" or $pushed.state == "offline" { $commits } else { [] }
            let state = if ($remoteDiff != null) and not $remoteDiff.kept {
                "rewritten"
            } else if $pushed.state == "offline" {
                "local-ahead"
            } else {
                $pushed.state
            }
            let result = {
                state: $state
                branch: $branch
                diff: $remoteDiff
                localFiles: $changes.files
                localInputs: $changes.inputs
                remoteInputs: ($remoteInputs | default [])
                pushed: $pending
            }
            if (branchHasReport $result) { printRepoHeading $repo }
            printBranchResult $repo $branch $result
        }
        # commit message format: "<HOST>: <message>" (or "Commit <date>" when no message is given)
        def buildMessage [message?: string] {
            $"${vars.host}: " + if ($message | is-empty) { $"Commit (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }
        }
''
