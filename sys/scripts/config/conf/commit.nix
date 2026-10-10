{ config, lib, com, pkgs, vars, self, ... }: {
    conf.subcommands.commit = ''
        # Usage: conf commit [message] [--host (-h) <host>] [--all (-a)] [--single (-s)]
        def "main commit" [message?: string, --host(-h): string, --all(-a), --single(-s)] {
            checkNoForeign
            if $all and $single {
                error make { msg: "--all and --single can't be used together" }
            }
            let target = (currentRepo $host)
            let common = "${vars.configPath}/common"
            let msg = (buildMessage $message)

            if not ($single and $target != $common) {
                repoSync $common --pause
                commitRepo $common $msg
                repoPush $common
            }

            if $target == $common {
                main perms
                return
            }

            let repos = if $all { hostRepos } else { [ $target ] }
            for repo in $repos {
                repoSync $repo --pause
                # re-lock only when common's HEAD actually moved
                if not $single and (lockedRev $repo) != (gitSafe $common rev-parse HEAD | complete | get stdout | str trim) {
                    updateCommonLock $repo
                }
                commitRepo $repo (if $all and $repo != $target { $"${vars.host}: Common flake has been updated" } else { $msg })
                repoPush $repo
            }
            main perms
        }
    '';
}
