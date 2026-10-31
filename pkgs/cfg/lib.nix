{ pkgs, vars }:
''
        # Config repos other than common and the cur mount.
        def hostRepos [] {
            ls ${vars.configPath} | where { |e| $e.type == dir and ($"($e.name)/.git" | path exists) } | get name | where { |n| ($n | path basename) not-in [ "common" "cur" ] }
        }
        # --host aliases: `cur` is this host's repo, `com`/`common` the common one; else a repo name under the config dir
        def hostRepo [host: string] {
            let dir = (if $host == "cur" { "${vars.host}" } else if $host in [ "com" "common" ] { "common" } else { $host })
            let repo = $"${vars.configPath}/($dir)"
            if not ($"($repo)/.git" | path exists) { error make { msg: $"($repo) is not a config repo" } }
            $repo
        }
        def --wrapped gitOut [repo: string, ...args: string] {
            gitSafe $repo ...$args | complete | get stdout | str trim
        }
        # repo to act on: --host wins; otherwise resolved by walking up from PWD and comparing device+inode,
        # so a bind mount (e.g. a directory bound to another host repo) resolves to the real repo; fallback is the host repo.
        # PWD inside common resolves to the host repo — common is touched alone only via --host com or --single
        def currentRepo [host?: string, --single] {
            if ($host | is-not-empty) { return (hostRepo $host) }
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
            let gitDir = (gitOut $repo rev-parse --git-dir)  # .git dir path, relative to the repo
            if ($"($repo)/($gitDir)/rebase-merge" | path exists) or ($"($repo)/($gitDir)/rebase-apply" | path exists) { error make { msg: $"($repo): rebase in progress, finish it first" } }
            if (gitSafe $repo symbolic-ref -q HEAD | complete | get exit_code) != 0 {  # fails on detached HEAD
                error make { msg: $"($repo): detached HEAD" }
            }
            $gitDir
        }
        # name of the checked-out branch; every repo is synced with the same-named branch on origin
        def repoBranch [repo: string] {
            gitOut $repo symbolic-ref -q --short HEAD
        }
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
        def fileRecord [repo: string, letter: string, path: string, displayPath?: string] {
            let fullPath = [$repo $path] | path join
            let date = if ($fullPath | path exists) {
                try { ls -D $fullPath | get 0 | get modified | format date '%Y-%m-%d %H:%M:%S' } catch { "?" }
            } else { "?" }
            { letter: $letter, path: ($displayPath | default $path), date: $date }
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
                let letter = [$indexStatus $worktreeStatus] | each { |mark| $marks | get --optional $mark } | where { |mark| $mark != null } | first | default "?"
                let path = ($line | str substring 3..)
                let oldPath = if $letter in [ "R" "C" ] {
                    $i = $i + 1
                    $entries | get $i
                } else { null }
                let displayPath = if $oldPath == null { $path } else { $"($oldPath) -> ($path)" }
                let unstaged = ($status == "??") or (($status | str substring 1..1) != " ")
                if not $unstaged_only or $unstaged { $files = ($files | append (fileRecord $repo $letter $path $displayPath)) }
                $i = $i + 1
            }
            $files
        }
        def commitRepo [repo: string, message: string, --no-add] {
            if not $no_add { gitSafe $repo add . }
            let files = if $no_add { worktreeFiles $repo --unstaged-only } else { [] }
            let staged = (gitSafe $repo diff --cached --name-only | complete | get stdout)
            let committed = not ($staged | is-empty)
            if $committed { silent { gitSafe $repo commit -m $message } }
            { files: $files, committed: $committed }
        }
        def commitAndPush [repo: string, message: string, remoteDiff?: record, --no-add] {
            let changes = (commitRepo $repo $message --no-add=$no_add)
            let branch = (repoBranch $repo)
            let remote = (gitOut $repo rev-parse -q --verify $"origin/($branch)")
            let local = (gitOut $repo rev-parse HEAD)
            let commits = (commitsToPush $repo $remote $local)
            let pushed = (repoPush $repo --report)
            if $pushed.state == "catastrophe" {
                let result = (($pushed | upsert localFiles $changes.files) | upsert remoteDiff $remoteDiff)
                if (branchHasReport $result) { printRepoHeading $repo }
                return (printBranchResult $repo $branch $result)
            }
            let pending = if $pushed.state == "pushed" or $pushed.state == "offline" { $commits } else { [] }
            let state = if ($remoteDiff != null) and not $remoteDiff.kept { "rewritten" } else { $pushed.state }
            let state = if $state == "offline" { "local-ahead" } else { $state }
            let result = { state: $state, branch: $branch, diff: $remoteDiff, localFiles: $changes.files, pushed: $pending }
            if (branchHasReport $result) { printRepoHeading $repo }
            printBranchResult $repo $branch $result
        }
        # commit message format: "<HOST>: <message>" (or "Commit <date>" when no message is given)
        def buildMessage [message?: string] {
            $"${vars.host}: " + if ($message | is-empty) { $"Commit (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }
        }
''
