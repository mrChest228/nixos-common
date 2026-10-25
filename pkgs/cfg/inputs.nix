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
        # lock changes of one commit, printed at the same indent as its files
        def printInputChanges [changes: list<record>, indent: string] {
            let followIndent = ($indent + "   ")
            for change in $changes {
                let path = $change.item.path
                if $change.kind == "added" {
                    let item = $change.item
                    let rev = if ($item.rev | is-empty) { "" } else { $item.rev | str substring 0..7 }
                    print $"($indent)($REPORT_COLOR.greenBold)+  ($path)  ($item.original)  ($rev)($REPORT_COLOR.reset)  ($REPORT_COLOR.darkGray)($item.date)($REPORT_COLOR.reset)"
                    if not ($item.follows | is-empty) { print $"($followIndent)follows: ($item.follows)" }
                } else if $change.kind == "removed" {
                    print $"($indent)($REPORT_COLOR.redBold)-  ($path)($REPORT_COLOR.reset)"
                } else if $change.kind == "updated" or $change.kind == "downgrade" {
                    let oldRev = if ($change.old.rev | is-empty) { "" } else { $change.old.rev | str substring 0..7 }
                    let newRev = if ($change.item.rev | is-empty) { "" } else { $change.item.rev | str substring 0..7 }
                    let color = if $change.kind == "updated" { $REPORT_COLOR.yellow } else { $REPORT_COLOR.magentaBold }
                    let mark = if $change.kind == "updated" { "~" } else { "v" }
                    print $"($indent)($color)($mark)  ($path)  ($oldRev) -> ($newRev)  ($REPORT_COLOR.darkGray)($change.old.date) -> ($change.item.date)($REPORT_COLOR.reset)"
                } else if $change.kind == "source" {
                    let followsChanged = $change.old.follows != $change.item.follows
                    let oldSource = if $followsChanged { $"follows: (if ($change.old.follows | is-empty) { "none" } else { $change.old.follows })" } else { $change.old.original }
                    let newSource = if $followsChanged { (if ($change.item.follows | is-empty) { "none" } else { $change.item.follows }) } else { $change.item.original }
                    print $"($indent)($REPORT_COLOR.yellowBold)>  ($path)  ($oldSource) -> ($newSource)($REPORT_COLOR.reset)"
                } else if $change.kind == "narHash" {
                    print $"($indent)($REPORT_COLOR.redBold)!  ($path): narHash changed for the same rev($REPORT_COLOR.reset)"
                }
            }
        }
''
