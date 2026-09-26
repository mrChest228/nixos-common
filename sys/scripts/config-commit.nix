{ config, lib, pkgs, vars, self, ... }: 
let
    script = pkgs.writeScriptBin "config-commit" ''
        #!${pkgs.nushell}/bin/nu
        # Run only with sudo!
        # Usage: ./config-commit <message|null>
        # Commits and pushed all the changes in the current folder
        def returnCode [code: int] {
            run-external "nu" "-c" $"exit ($code)"
        }
        def --env silent [action: closure] {
            let src = (view source $action)
            returnCode (
                try {
                    let res = (do $action | complete)
                    if $res.exit_code != 0 {
                       print $"($res.stdout)\n(ansi red)($res.stderr)\n(ansi red_bold)Command ($src) FAILED \(exit code ($res.exit_code)\)(ansi rst)"
                    }
                    $res.exit_code
                } catch { |e|
                    print ($e.rendered? | default $e)
                    1
                }
            )
        }
        def main [message?: string] {
            let msg = "${vars.host}: " + if ($message | is-empty) { $"Commit (date now | format date '%Y-%m-%d %H:%M:%S %:z')" } else { $message }
            git add .
            let push = (
                if not ((git status -s) | is-empty) {
                    echo "File changes:"

                    # Changes with time printing
                    let colors = [
                        { code: "?", color: (ansi dark_gray) }
                        { code: "!", color: (ansi dark_gray) }
                        { code: "A", color: (ansi green) }
                        { code: "M", color: (ansi yellow) }
                        { code: "D", color: (ansi red) }
                        { code: "R", color: (ansi cyan) }
                        { code: "C", color: (ansi magenta) }
                        { code: "T", color: (ansi blue) }
                        { code: "U", color: (ansi red) }
                    ]
                    let changesGit = (git status --porcelain=v1 -z | split row (char nul) | drop)
                    mut changes = []
                    mut i = 0
                    loop {
                        if $i >= ($changesGit | length) {
                            break
                        }
                        let line = ($changesGit | get $i)
                        let x = ($line | str substring 0..0)
                        let color = ($colors | where code == $x | if ($in | length) != 1 { ansi red } else { $in | first | get color })
                        mut pths = [($line | str substring 3..)]
                        if ($x == "R" or $x == "C") {
                            $i = $i + 1
                            $pths = ($pths | append ($changesGit | get $i))
                        }
                        let pth = ($pths | get 0)
                        let time = if ($pth | path exists) { ls -D $pth | get 0 | get modified | format date '%Y-%m-%d %H:%M:%S' } else { "?" }

                        if ($pths | get 0 | str contains " ") {
                            $pths = ($pths | upsert 0 { |pth| $"\"($pth)\"" })
                        }
                        if (($pths | length) == 2 and ($pths | get 1 | str contains " ")) {
                            $pths = ($pths | upsert 1 { |pth| $"\"($pth)\"" })
                        }

                        let pthTo = if ($pths | length) == 2 { $" -> ($pths | get 0)" } else { "" }
                        print $"($color)($x)  ($pths | last)($pthTo)(ansi rst) ($time)"
                        $i = $i + 1
                    }
                    silent { git commit -m $msg }
                    true
                } else {
                    print $"(ansi cyan)Nothing to commit(ansi rst)"
                    if (not ($message | is-empty) and ($msg != (git log -1 --format=%s))) {
                        let reply = (input "Do you want to rename the last commit? [Y/n]: " | str lowercase)
                        if ($reply == "" or $reply == "y" or $reply == "ye" or $reply == "yes") {
                            silent { git commit --amend -m $msg }
                            true
                        } else { false }
                    } else { false }
                }
            )
            if $push {
                git --no-pager log -1 --oneline --format="%C(magenta)%h%C(auto)%d %s"
                let start = (date now)
                silent { sudo nu -c 'with-env { GIT_SSH_COMMAND: "ssh -i /root/.ssh/nixos-config -o IdentitiesOnly=yes" } { git push --force-with-lease }' }
                print $"(ansi green_bold)Successful push in ((date now) - $start)(ansi rst)"
            }
        }
    '';
in {
    environment.etc."nixos/config-commit".source = script;
}
