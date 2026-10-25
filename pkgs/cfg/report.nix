{ pkgs, vars }:
''
        const REPORT_INDENT = { branch: "   ", section: "      ", item: "         ", detail: "            " }
        const REPORT_COLOR = { reset: (ansi --escape '0m'), repo: (ansi --escape '1;37m'), branch: (ansi --escape '34m'), section: (ansi --escape '3;36m'), red: (ansi --escape '31m'), redBold: (ansi --escape '1;31m'), green: (ansi --escape '32m'), greenBold: (ansi --escape '1;32m'), yellow: (ansi --escape '33m'), yellowBold: (ansi --escape '1;33m'), cyan: (ansi --escape '36m'), magenta: (ansi --escape '35m'), magentaBold: (ansi --escape '1;35m'), blue: (ansi --escape '34m'), white: (ansi --escape '37m'), yellowBright: (ansi --escape '93m'), darkGray: (ansi --escape '90m') }
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
        def changeMark [letter: string] {
            match $letter {
                "" => { text: " ", color: $REPORT_COLOR.yellowBright }
                "A" => { text: "+", color: $REPORT_COLOR.green }
                "D" => { text: "-", color: $REPORT_COLOR.red }
                "M" => { text: "~", color: $REPORT_COLOR.yellowBright }
                "R" => { text: ">", color: $REPORT_COLOR.cyan }
                "C" => { text: "=", color: $REPORT_COLOR.magenta }
                "T" => { text: "T", color: $REPORT_COLOR.blue }
                "U" => { text: "!", color: $REPORT_COLOR.red }
                "?" => { text: ".", color: $REPORT_COLOR.darkGray }
                _ => { text: $letter, color: $REPORT_COLOR.blue }
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
        def printFileLine [indent: string, letter: string, path: string, date: string, --dark] {
            let mark = (changeMark $letter)
            let color = if $dark { $REPORT_COLOR.darkGray } else { $mark.color }
            let dateText = if ($date | is-empty) { "" } else { $"  ($REPORT_COLOR.darkGray)($date)($REPORT_COLOR.reset)" }
            print $"($indent)($color)($mark.text)  ($path)($REPORT_COLOR.reset)($dateText)"
        }
        def printLocalFiles [files: list<record>] {
            for file in $files {
                printFileLine $REPORT_INDENT.item $file.letter $file.path $file.date --dark
            }
        }
        # one row per file: status from --name-status, +added/-deleted lines from --numstat (same order; "-" for binary);
        # --mtime adds the worktree modification time (local commits only, fetched files carry the pull time)
        def printCommitFiles [repo: string, hash: string, --mtime] {
            let rows = (gitSafe $repo diff-tree --no-commit-id -r --name-status -M -C --root $hash | complete | get stdout | lines)
            let stats = (gitSafe $repo diff-tree --no-commit-id -r --numstat -M -C --root $hash | complete | get stdout | lines)
            for entry in ($rows | enumerate) {
                let parts = ($entry.item | split row (char tab))
                let letter = ($parts | first | str substring 0..0)
                let newPath = ($parts | last)
                let path = if $letter in [ "R" "C" ] { $"($parts | get 1) -> ($newPath)" } else { $newPath }
                let stat = ($stats | get -o $entry.index | default "" | split row (char tab))
                let counts = if $letter == "T" or ($stat | length) < 2 or $stat.0 == "-" { "" } else {
                    $" ($REPORT_COLOR.white)\(($REPORT_COLOR.green)+($stat.0)($REPORT_COLOR.white) ($REPORT_COLOR.red)-($stat.1)($REPORT_COLOR.white)\)($REPORT_COLOR.reset)"
                }
                # no mtime for files absent from the worktree (other branch), "?" only for deletions
                let date = if $mtime { (fileRecord $repo $letter $newPath).date } else { "" }
                let date = if $date == "?" and $letter != "D" { "" } else { $date }
                printFileLine $REPORT_INDENT.detail $letter $"($path)($counts)" $date
            }
        }
        # with lock changes a commit gets two blocks, "Inputs:" then "Files:", both at the file indent
        def printCommitDetails [repo: string, hash: string, --mtime] {
            let changes = (commitFlakeInputs $repo $hash).changes
            if ($changes | is-not-empty) {
                print $"($REPORT_INDENT.detail)($REPORT_COLOR.section)Inputs:($REPORT_COLOR.reset)"
                printInputChanges $changes $REPORT_INDENT.detail
                print ""
                print $"($REPORT_INDENT.detail)($REPORT_COLOR.section)Files:($REPORT_COLOR.reset)"
            }
            printCommitFiles $repo $hash --mtime=$mtime
        }
        def printHistoryCommit [repo: string, letter: string, commit: record, --mtime] {
            let mark = (changeMark $letter)
            let hash = ($commit.hash | str substring 0..7)
            print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($hash)($REPORT_COLOR.reset) ($mark.color)($commit.subject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($commit.date)($REPORT_COLOR.reset)"
            printCommitDetails $repo $commit.hash --mtime=$mtime
        }
        # renamed (R) or only rehashed (no mark, yellow) commit; the tree is unchanged, so only the lock changes are listed
        def printRewrittenCommit [repo: string, letter: string, event: record] {
            let mark = (changeMark $letter)
            let oldHash = ($event.oldHash | str substring 0..7)
            let newHash = ($event.newHash | str substring 0..7)
            print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($oldHash)($REPORT_COLOR.reset) ($mark.color)($event.oldSubject) ($REPORT_COLOR.white)->($REPORT_COLOR.reset) ($REPORT_COLOR.magenta)($newHash)($REPORT_COLOR.reset) ($mark.color)($event.newSubject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($event.date)($REPORT_COLOR.reset)"
            printInputChanges (commitFlakeInputs $repo $event.newHash).changes $REPORT_INDENT.detail
        }
        def printRemoteDiff [repo: string, diff: record] {
            let events = ($diff.events? | default [])
            if ($events | is-empty) { return }
            printSectionHeading "remote"
            for event in $events {
                if $event.kind == "added" {
                    printHistoryCommit $repo "A" $event.commit
                } else if $event.kind == "renamed" {
                    printRewrittenCommit $repo "R" $event
                } else if $event.kind == "rehashed" {
                    printRewrittenCommit $repo "" $event
                }
            }
        }
        def printLocalDiff [repo: string, files: list<record>, commits: list<record>] {
            if ($files | is-empty) and ($commits | is-empty) { return }
            printSectionHeading "local"
            printLocalFiles $files
            for commit in $commits {
                printHistoryCommit $repo "A" $commit --mtime
            }
        }
        def printCatastrophe [repo: string, diff: record] {
            let reason = if ($diff.reason? | default "") == "narHash" { "narHash changed for the same rev" } else { $"($diff.deleted | length) commits deleted" }
            print -e $"($REPORT_INDENT.item)($REPORT_COLOR.redBold)CATASTROPHE: ($reason), branch skipped($REPORT_COLOR.reset)"
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
                    let short = (gitOut $repo rev-parse --short $result.candidate)
                    let unresolved = ("CATASTROPHE still unresolved (origin " + $short + "), branch skipped")
                    print -e ($REPORT_INDENT.section + $REPORT_COLOR.redBold + $unresolved + $REPORT_COLOR.reset)
                    return
                }
            }
            printSectionHeading "remote"
            printCatastrophe $repo $result.diff
            printLocalDiff $repo ($result.localFiles? | default []) []
            mkdir ($marker | path dirname)
            $result.candidate | save --force $marker
        }
        def printQuietCatastrophe [repo: string, branch: string, result: record] {
            printQuietCatastropheAt $repo $branch $result "/run/nixos-config-reported"
        }
        def clearCatastropheMarker [repo: string, branch: string] {
            let marker = (catastropheMarkerPath $repo $branch)
            if ($marker | path exists) { rm $marker }
        }
        def branchHasReport [result: record] {
            if $result.state in [ "catastrophe" "both-moved" "conflict" ] { return true }
            let diff = $result.diff? | default null
            let localFiles = $result.localFiles? | default []
            let pushed = $result.pushed? | default []
            let remoteEvents = if $diff == null { [] } else { $diff.events? | default [] }
            let rewritten = if $result.state == "rewritten" {
                if $diff == null { false } else { ($diff.deleted | is-not-empty) or ($diff.added | is-not-empty) }
            } else { false }
            ($result.state in [ "catastrophe" "both-moved" "conflict" ]) or ($localFiles | is-not-empty) or ($pushed | is-not-empty) or ($remoteEvents | is-not-empty) or $rewritten
        }
        def printBranchResult [repo: string, branch: string, result: record, --quiet] {
            if $result.state == "catastrophe" {
                printBranchHeading $branch
                let direction = $result.direction? | default "remote"
                if $direction == "remote" {
                    printSectionHeading "remote"
                    printCatastrophe $repo $result.diff
                    printLocalDiff $repo ($result.localFiles? | default []) []
                } else {
                    let remoteDiff = $result.remoteDiff? | default null
                    if $remoteDiff != null and not $remoteDiff.kept {
                        printSectionHeading "remote"
                        for commit in $remoteDiff.deleted { printHistoryCommit $repo "D" $commit }
                        for commit in $remoteDiff.added { printHistoryCommit $repo "A" $commit }
                    } else {
                        printRemoteDiff $repo ($remoteDiff | default { events: [] })
                    }
                    printLocalDiff $repo ($result.localFiles? | default []) []
                    if ($result.localFiles? | default [] | is-empty) { printSectionHeading "local" }
                    printCatastrophe $repo $result.diff
                }
                return true
            }
            if $result.state == "both-moved" {
                printBranchHeading $branch
                print $"($REPORT_INDENT.section)($REPORT_COLOR.redBold)both local and origin have new commits, switch to it to sync, branch skipped($REPORT_COLOR.reset)"
                return true
            }
            if $result.state == "conflict" {
                printBranchHeading $branch
                let files = $result.conflictFiles? | default []
                let where = if ($files | is-empty) { "" } else { " in " + ($files | str join ", ") }
                print $"($REPORT_INDENT.section)($REPORT_COLOR.redBold)Merge conflict($where), branch skipped($REPORT_COLOR.reset)"
                return true
            }
            let diff = $result.diff?
            let localFiles = $result.localFiles? | default []
            let pushed = $result.pushed? | default []
            let remoteChanged = if $result.state != "local-ahead" and $diff != null {
                (($diff.events? | default []) | is-not-empty)
            } else { false }
            let rewritten = if $result.state == "rewritten" {
                if $diff == null { false } else { ($diff.deleted | is-not-empty) or ($diff.added | is-not-empty) }
            } else { false }
            if not $remoteChanged and not $rewritten and ($localFiles | is-empty) and ($pushed | is-empty) { return false }
            printBranchHeading $branch
            if $result.state == "rewritten" {
                printSectionHeading "remote"
                for commit in $diff.deleted { printHistoryCommit $repo "D" $commit }
                for commit in $diff.added { printHistoryCommit $repo "A" $commit }
            } else if $remoteChanged {
                printRemoteDiff $repo ($diff | default { events: [] })
            }
            printLocalDiff $repo $localFiles $pushed
            true
        }
        def printRepoResults [repo: string, results: list<record>, --quiet] {
            let visible = ($results | where { |entry| branchHasReport $entry.result })
            if ($visible | is-empty) { return false }
            printRepoHeading $repo
            for entry in $visible {
                if $quiet and $entry.result.state == "catastrophe" and ($entry.result.direction? | default "remote") == "remote" { printQuietCatastrophe $repo $entry.branch $entry.result } else { printBranchResult $repo $entry.branch $entry.result --quiet=$quiet }
            }
            true
        }
        def printEverythingUpToDate [] {
            print $"($REPORT_COLOR.darkGray)everything up to date($REPORT_COLOR.reset)"
        }
''
