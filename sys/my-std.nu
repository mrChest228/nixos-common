# runs a command as root with the caller's own nushell config, so aliases and defs still work
export def --wrapped nudo [...rest: string] {
    if ($rest | is-empty) { return }

    mut nwRest = ($rest | each { |s|
        if ($s | str contains " ") { $"\"($s)\"" } else { $s } # Adds " if argument contains spaces
    })
    $nwRest.0 = ($nwRest.0 | str replace -a -r '^"|"$' '') # Remove " from the start and the end of command ("ls | to nuon", for example)

    let cmd = ($nwRest | str join " ")

    # absolute path to the running nu: sudo resolves `nu` through the caller's PATH otherwise
    sudo $nu.current-exe --config $nu.config-path --env-config $nu.env-path -c $cmd
}
export def returnCode [code: int] {
    # $nu.current-exe is the running binary: works when nushell isn't on PATH (scripts run via the store path)
    run-external $nu.current-exe "-c" $"exit ($code)"
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
