export def returnCode [code: int] {
    run-external "nu" "-c" $"exit ($code)"
}
export def --env silent [action: closure] {
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
