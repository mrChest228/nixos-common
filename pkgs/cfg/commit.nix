{ vars }:
''
        # Usage: cfg commit [message] [--host (-h) <host|cur|com>] [--all (-a)] [--single (-s)] [--no-add (-n)]
        def "main commit" [message?: string, --host(-h): string, --all(-a), --single(-s), --no-add(-n)] {
            checkNoForeign
            if $all and $single { error make { msg: "--all and --single can't be used together" } }
            let target = (currentRepo $host --single=$single)
            let common = "${vars.configPath}/common"
            let msg = (buildMessage $message)
            mut anyPrinted = false

            if not ($single and $target != $common) {
                let sync = (repoSync $common --pause)
                if $sync.online { clearCatastropheMarker $common (repoBranch $common) }
                let printed = (commitAndPush $common $msg $sync.diff? --no-add=$no_add)
                $anyPrinted = $anyPrinted or $printed
            }

            if $target == $common {
                main perms
                if not $anyPrinted { printEverythingUpToDate }
                return
            }

            let repos = if $all { hostRepos } else { [ $target ] }
            for repo in $repos {
                let sync = (repoSync $repo --pause)
                if $sync.online { clearCatastropheMarker $repo (repoBranch $repo) }
                # re-lock only when common's HEAD actually moved
                if not $single and (lockedRev $repo) != (gitOut $common rev-parse HEAD) {  # common's current commit
                    updateCommonLock $repo
                }
                let printed = (commitAndPush $repo (if $all and $repo != $target { $"${vars.host}: Common flake has been updated" } else { $msg }) $sync.diff? --no-add=$no_add)
                $anyPrinted = $anyPrinted or $printed
            }
            main perms
            if not $anyPrinted { printEverythingUpToDate }
        }
''
