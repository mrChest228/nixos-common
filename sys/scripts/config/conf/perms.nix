{ config, lib, com, pkgs, vars, self, ... }: {
    conf.subcommands.perms = ''
        # Git runs here as root, so pulled/created files are root-owned; this fixes ownership under ${vars.configPath}.
        # Only wrong entries are touched: chown bumps ctime -> git rescans every file, and the path
        # unit below would retrigger itself forever.
        def "main perms" [] {
            let firstUser = "${builtins.head vars.users}"
            let users = [ ${lib.concatMapStringsSep " " (u: "\"${u}\"") vars.users} ]
            let foreign = (foreignHmDirs)
            let prunes = ($foreign | each { |d| [ "-path" $d "-prune" "-o" ] } | flatten)
            for repo in ([ "${vars.configPath}/common" ] ++ (hostRepos)) {
                let hm = $"($repo)/hm"
                if ($hm | path exists) {
                    ^find $repo -path $hm -prune -o ! -user root -exec chown -h root {} +
                    # hm belongs to root (1755) with an ACL for the first user; the sticky bit stops anyone
                    # from renaming hm/root — `mv hm/root x; mkdir hm/root` would feed root someone else's
                    # code on the next passwordless reconf. The ACL's mask shows up as group bits in stat
                    # (hm looks 1775), so hm is excluded from the chmod steps below.
                    if ((^stat -c %U $hm | complete).stdout | str trim) != "root" { ^chown root $hm }
                    if not (((^stat -c %a $hm | complete).stdout | str trim) in [ "1755" "1775" ]) { ^chmod 1755 $hm }
                    let wantAcl = [ "user::rwx" $"user:($firstUser):rwx" "group::r-x" "mask::rwx" "other::r-x" ] | str join "\n"
                    if ((^${pkgs.acl}/bin/getfacl -cp $hm | complete).stdout | str trim) != $wantAcl {
                        ^${pkgs.acl}/bin/setfacl -bm mask::rwx $"u:($firstUser):rwx" $hm
                    }
                    for dir in (^find $hm -mindepth 1 -maxdepth 1 -type d | lines) {
                        if ($foreign | any { |d| $d == $dir }) { continue }
                        let name = ($dir | path basename)
                        # files root evaluates must not be user-writable: update/reconf run without a
                        # password, that would be a passwordless path to root
                        let owner = if $name == "root" { "root" } else if ($users | any { |u| $u == $name }) { $name } else { $firstUser }
                        ^find $dir ! -user $owner -exec chown -h $owner {} +
                    }
                    ^find $hm -mindepth 1 -maxdepth 1 ! -type d ! -user $firstUser -exec chown -h $firstUser {} +
                } else {
                    ^find $repo ! -user root -exec chown -h root {} +
                }
                # modes: readable by all (dirs need +x to enter), executable stays as git has it,
                # write only by the owner, no setuid/setgid (foreign dirs are pruned: never touched)
                ^find $repo ...$prunes ! -type l ! -path $hm -perm /022 -exec chmod go-w {} +
                ^find $repo ...$prunes ! -type l ! -path $hm -perm /6000 -exec chmod ug-s {} +
                ^find $repo ...$prunes -type d ! -path $hm ! -perm -555 -exec chmod a+rx {} +
                ^find $repo ...$prunes -type f ! -path $hm ! -perm -444 -exec chmod a+r {} +
            }
            for d in $foreign {
                reportProblem "conf perms" $"foreign hm dir ($d): fix its owner and run conf perms again" --quiet
            }
            if ($foreign | is-not-empty) { exit 1 }
        }
    '';
    systemd.services.conf-perms = {
        description = "Fix ownership and modes of config repos";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.acl pkgs.coreutils pkgs.findutils pkgs.nushell pkgs.util-linux ];
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
