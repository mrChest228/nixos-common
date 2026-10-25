{ pkgs, vars }:
''
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
                if ($input | describe | str starts-with "list") { $current = (resolveFollow $nodes $root $input) } else { $current = $input }
            }
            $current
        }
        def walkLockInput [nodes: record, root: string, input: any, path: string, ancestors: list<string>] {
            if ($input | describe | str starts-with "list") {
                let follows = ($input | str join "/")
                let target = (resolveFollow $nodes $root $input)
                if $target == null { return [{ path: $path, follows: $follows, original: "", rev: "", lastModified: null, date: "", narHash: "" }] }
                walkLockNode $nodes $root $target $path $follows $ancestors
            } else {
                walkLockNode $nodes $root $input $path "" $ancestors
            }
        }
        def walkLockNode [nodes: record, root: string, nodeId: string, path: string, follows: string, ancestors: list<string>] {
            let node = ($nodes | get --optional $nodeId)
            if $node == null { return [{ path: $path, follows: $follows, original: "", rev: "", lastModified: null, date: "", narHash: "" }] }
            let locked = ($node.locked? | default {})
            let lastModified = ($locked.lastModified? | default null)
            let date = if $lastModified == null { "" } else {
                try { $lastModified * 1_000_000_000 | into datetime | format date '%Y-%m-%d %H:%M:%S' } catch { "" }
            }
            let entry = { path: $path, follows: $follows, original: (inputSource ($node.original? | default {})), rev: ($locked.rev? | default ""), lastModified: $lastModified, date: $date, narHash: ($locked.narHash? | default "") }
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
                if not ($kind | is-empty) { $changes = ($changes | append { kind: $kind, old: $old, item: $current }) }
            }
            for old in $before {
                if $old.path not-in $afterPaths { $changes = ($changes | append { kind: "removed", item: $old }) }
            }
            $changes | sort-by { |change| $change.item.path }
        }
        def lockText [repo: string, commit: string] {
            let result = (gitSafe $repo show $"($commit):flake.lock" | complete)
            if $result.exit_code == 0 { $result.stdout } else { "" }
        }
        def commitFlakeInputs [repo: string, hash: string] {
            let parent = (gitSafe $repo rev-parse -q --verify $"($hash)^" | complete)
            let beforeText = if $parent.exit_code == 0 { lockText $repo ($parent.stdout | str trim) } else { "" }
            let afterText = (lockText $repo $hash)
            let before = (flakeLockInputs $beforeText)
            let after = (flakeLockInputs $afterText)
            { touched: ($beforeText != $afterText), changes: (compareFlakeInputs $before $after) }
        }
        def shortRev [rev: string] { if ($rev | is-empty) { "" } else { $rev | str substring 0..7 } }
        # Lock changes of one commit at the indent of its files: one bold row per root input, its changed
        # follows below in white (name -> target). Nested entries that merely track an updated root input are skipped.
        def printInputChanges [changes: list<record>, indent: string] {
            let nestedIndent = ($indent + "   ")
            # nested entries worth a line: follows that appeared, vanished, moved or point nowhere, and the
            # contents of an added input; the rest only repeats the root row (e.g. a follows of an updated input)
            let nested = ($changes | where { |change| $change.item.path | str contains "/" } | where { |change|
                let follows = $change.item.follows
                let root = ($change.item.path | split row "/" | first)
                let rootAdded = ($changes | any { |other| $other.item.path == $root and $other.kind == "added" })
                let missing = (not ($follows | is-empty)) and ($change.item.rev | is-empty) and ($change.item.original | is-empty)
                $missing or $change.kind == "removed" or ($change.kind == "source" and $change.old.follows != $follows) or ($change.kind == "added" and ($rootAdded or not ($follows | is-empty)))
            })
            let roots = (($changes | where { |change| not ($change.item.path | str contains "/") }) ++ $nested | each { |change| $change.item.path | split row "/" | first } | uniq | sort)
            for root in $roots {
                let own = ($changes | where { |change| $change.item.path == $root } | get -o 0)
                let nested = ($nested | where { |change| $change.item.path | str starts-with ($root + "/") })
                if $own == null {
                    print $"($indent)($REPORT_COLOR.yellowBold)~  ($root)($REPORT_COLOR.reset)"
                } else if $own.kind == "added" {
                    print $"($indent)($REPORT_COLOR.greenBold)+  ($root)  ($own.item.original)  (shortRev $own.item.rev)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($own.item.date)($REPORT_COLOR.reset)"
                } else if $own.kind == "removed" {
                    print $"($indent)($REPORT_COLOR.redBold)-  ($root)($REPORT_COLOR.reset)"
                    continue
                } else if $own.kind in [ "updated" "downgrade" ] {
                    print $"($indent)($REPORT_COLOR.yellowBold)~  ($root)  (shortRev $own.old.rev) -> (shortRev $own.item.rev)  ($REPORT_COLOR.darkGray)($own.old.date) -> ($own.item.date)($REPORT_COLOR.reset)"
                } else if $own.kind == "source" {
                    print $"($indent)($REPORT_COLOR.yellowBold)~  ($root)  ($own.old.original) -> ($own.item.original)($REPORT_COLOR.reset)"
                } else if $own.kind == "narHash" {
                    print $"($indent)($REPORT_COLOR.redBold)!  ($root)  narHash changed for the same rev($REPORT_COLOR.reset)"
                }
                for change in $nested {
                    let name = ($change.item.path | str substring (($root | str length) + 1)..)
                    let follows = $change.item.follows
                    if ($follows | is-empty) {
                        print $"($nestedIndent)($REPORT_COLOR.white)($name)  ($change.item.original)  (shortRev $change.item.rev)($REPORT_COLOR.reset)"
                    } else if ($change.item.rev | is-empty) and ($change.item.original | is-empty) {
                        print $"($nestedIndent)($REPORT_COLOR.redBold)($name) -> ($follows)  missing($REPORT_COLOR.reset)"
                    } else if $change.kind == "removed" {
                        print $"($nestedIndent)($REPORT_COLOR.white)($name) -> ($follows)  removed($REPORT_COLOR.reset)"
                    } else if $change.kind == "source" {
                        print $"($nestedIndent)($REPORT_COLOR.white)($name) -> ($follows)  \(was ($change.old.follows | default "none")\)($REPORT_COLOR.reset)"
                    } else {
                        print $"($nestedIndent)($REPORT_COLOR.white)($name) -> ($follows)($REPORT_COLOR.reset)"
                    }
                }
            }
        }
''
