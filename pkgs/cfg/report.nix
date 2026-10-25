{ pkgs, vars }:
''
        const REPORT_INDENT = { branch: "   ", section: "      ", item: "         ", detail: "            " }
        const REPORT_COLOR = { reset: (ansi --escape '0m'), repo: (ansi --escape '1;37m'), branch: (ansi --escape '34m'), section: (ansi --escape '3;36m'), red: (ansi --escape '31m'), redBold: (ansi --escape '1;31m'), green: (ansi --escape '32m'), greenBold: (ansi --escape '1;32m'), yellow: (ansi --escape '33m'), yellowBold: (ansi --escape '1;33m'), cyan: (ansi --escape '36m'), magenta: (ansi --escape '35m'), magentaBold: (ansi --escape '1;35m'), blue: (ansi --escape '34m'), white: (ansi --escape '37m'), darkGray: (ansi --escape '90m') }
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
                "" => { text: " ", color: $REPORT_COLOR.reset }
                "A" => { text: "+", color: $REPORT_COLOR.green }
                "D" => { text: "-", color: $REPORT_COLOR.red }
                "M" => { text: "~", color: $REPORT_COLOR.yellow }
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
        # one row per file: status from --name-status, +added/-deleted lines from --numstat (same order; "-" for binary)
        def printCommitFiles [repo: string, hash: string] {
            let rows = (gitSafe $repo diff-tree --no-commit-id -r --name-status -M -C --root $hash | complete | get stdout | lines)
            let stats = (gitSafe $repo diff-tree --no-commit-id -r --numstat -M -C --root $hash | complete | get stdout | lines)
            for entry in ($rows | enumerate) {
                let parts = ($entry.item | split row (char tab))
                let letter = ($parts | first | str substring 0..0)
                let path = if $letter in [ "R" "C" ] { $"($parts | get 1) -> ($parts | get 2)" } else { $parts | get 1 }
                let stat = ($stats | get -o $entry.index | default "" | split row (char tab))
                let counts = if $letter == "T" or ($stat | length) < 2 or $stat.0 == "-" { "" } else {
                    $" ($REPORT_COLOR.white)\(($REPORT_COLOR.green)+($stat.0)($REPORT_COLOR.white) ($REPORT_COLOR.red)-($stat.1)($REPORT_COLOR.white)\)($REPORT_COLOR.reset)"
                }
                printFileLine $REPORT_INDENT.detail $letter $"($path)($counts)" ""
            }
        }
        def printHistoryCommit [repo: string, letter: string, commit: record, --quiet] {
            let mark = (changeMark $letter)
            let hash = ($commit.hash | str substring 0..7)
            print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($hash)($REPORT_COLOR.reset) ($mark.color)($commit.subject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($commit.date)($REPORT_COLOR.reset)"
            printCommitFiles $repo $commit.hash
            let inputs = (commitFlakeInputs $repo $commit.hash)
            if $inputs.touched { printInputChanges $repo $inputs.changes $REPORT_INDENT.detail --quiet=$quiet }
        }
        def printRewrittenCommit [repo: string, letter: string, event: record, --quiet] {
            let mark = (changeMark $letter)
            let oldHash = ($event.oldHash | str substring 0..7)
            let newHash = ($event.newHash | str substring 0..7)
            print $"($REPORT_INDENT.item)($mark.color)($mark.text)  ($REPORT_COLOR.magenta)($oldHash)($REPORT_COLOR.reset) ($mark.color)($event.oldSubject) -> ($REPORT_COLOR.magenta)($newHash)($REPORT_COLOR.reset) ($mark.color)($event.newSubject)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($event.date)($REPORT_COLOR.reset)"
            let inputs = (commitFlakeInputs $repo $event.newHash)
            if $inputs.touched { printInputChanges $repo $inputs.changes $REPORT_INDENT.detail --quiet=$quiet }
        }
        def printRemoteDiff [repo: string, diff: record, --quiet] {
            let events = ($diff.events? | default [])
            if ($events | is-empty) { return }
            printSectionHeading "remote"
            for event in $events {
                if $event.kind == "added" {
                    printHistoryCommit $repo "A" $event.commit --quiet=$quiet
                } else if $event.kind == "renamed" {
                    printRewrittenCommit $repo "R" $event --quiet=$quiet
                } else if $event.kind == "rehashed" {
                    printRewrittenCommit $repo "" $event --quiet=$quiet
                }
            }
        }
        def printLocalDiff [repo: string, files: list<record>, commits: list<record>, --quiet] {
            if ($files | is-empty) and ($commits | is-empty) { return }
            printSectionHeading "local"
            printLocalFiles $files
            for commit in $commits {
                printHistoryCommit $repo "A" $commit --quiet=$quiet
            }
        }
        def printCatastrophe [repo: string, diff: record, --quiet] {
            print -e $"($REPORT_INDENT.item)($REPORT_COLOR.redBold)CATASTROPHE: ($diff.deleted | length) commits deleted, branch skipped($REPORT_COLOR.reset)"
            for commit in $diff.deleted {
                printHistoryCommit $repo "D" $commit --quiet=$quiet
            }
            for commit in $diff.added {
                printHistoryCommit $repo "A" $commit --quiet=$quiet
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
                    let unresolved = ("CATASTROPHE still unresolved (origin " + $short + ")")
                    print -e ($REPORT_INDENT.section + $REPORT_COLOR.redBold + $unresolved + $REPORT_COLOR.reset)
                    return
                }
            }
            printSectionHeading "remote"
            printCatastrophe $repo $result.diff --quiet
            printLocalDiff $repo ($result.localFiles? | default []) [] --quiet
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
                    printCatastrophe $repo $result.diff --quiet=$quiet
                    printLocalDiff $repo ($result.localFiles? | default []) [] --quiet=$quiet
                } else {
                    let remoteDiff = $result.remoteDiff? | default null
                    if $remoteDiff != null and not $remoteDiff.kept {
                        printSectionHeading "remote"
                        for commit in $remoteDiff.deleted { printHistoryCommit $repo "D" $commit --quiet=$quiet }
                        for commit in $remoteDiff.added { printHistoryCommit $repo "A" $commit --quiet=$quiet }
                    } else {
                        printRemoteDiff $repo ($remoteDiff | default { events: [] }) --quiet=$quiet
                    }
                    printLocalDiff $repo ($result.localFiles? | default []) [] --quiet=$quiet
                    if ($result.localFiles? | default [] | is-empty) { printSectionHeading "local" }
                    printCatastrophe $repo $result.diff --quiet=$quiet
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
                for commit in $diff.deleted { printHistoryCommit $repo "D" $commit --quiet=$quiet }
                for commit in $diff.added { printHistoryCommit $repo "A" $commit --quiet=$quiet }
            } else if $remoteChanged {
                printRemoteDiff $repo ($diff | default { events: [] }) --quiet=$quiet
            }
            printLocalDiff $repo $localFiles $pushed --quiet=$quiet
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
