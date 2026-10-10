{ config, lib, com, pkgs, vars, self, ... }: {
    conf.subcommands.perms = ''
        # Git runs here as root, so pulled/created files are root-owned; this fixes ownership under ${vars.configPath}.
        # Only wrong entries are touched: chown bumps ctime -> git rescans every file, and the path
        # unit below would retrigger itself forever.
        def "main perms" [] {
            let firstUser = "${builtins.head vars.users}"
            let users = [ ${lib.concatMapStringsSep " " (u: "\"${u}\"") vars.users} ]
            for repo in ([ "${vars.configPath}/common" ] ++ (hostRepos)) {
                let hm = $"($repo)/hm"
                if ($hm | path exists) {
                    ^find $repo -path $hm -prune -o ! -user root -exec chown -h root {} +
                    if ((^stat -c %U $hm | complete).stdout | str trim) != $firstUser { ^chown -h $firstUser $hm }
                    for dir in (^find $hm -mindepth 1 -maxdepth 1 -type d | lines) {
                        let name = ($dir | path basename)
                        # the root HM imports only hm/root, which is root-owned: files root evaluates must not
                        # be user-writable because update/reconf run without a password — that would be a
                        # passwordless path to root. Users may import from hm/root: reading root's files is safe.
                        let owner = if $name == "root" { "root" } else if ($users | any { |u| $u == $name }) { $name } else { $firstUser }
                        ^find $dir ! -user $owner -exec chown -h $owner {} +
                    }
                    ^find $hm -mindepth 1 -maxdepth 1 ! -type d ! -user $firstUser -exec chown -h $firstUser {} +
                } else {
                    ^find $repo ! -user root -exec chown -h root {} +
                }
                # modes: readable by all (dirs need +x to enter), executable stays as git has it,
                # write only by the owner, no setuid/setgid
                ^find $repo ! -type l -perm /022 -exec chmod go-w {} +
                ^find $repo ! -type l -perm /6000 -exec chmod ug-s {} +
                ^find $repo -type d ! -perm -555 -exec chmod a+rx {} +
                ^find $repo -type f ! -perm -444 -exec chmod a+r {} +
            }
        }
    '';
    systemd.services.conf-perms = {
        description = "Fix ownership and modes of config repos";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
            Type = "oneshot";
            ExecStart = "${config.config-scripts.packages.conf}/bin/conf perms";
        };
    };
    # a root-created hm/<user> must be handed to that user; minimal-chown keeps this from retriggering itself
    systemd.paths.conf-perms = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = [ "${vars.configPath}/common/hm" "${vars.configPath}/${vars.host}/hm" ];
    };
}
