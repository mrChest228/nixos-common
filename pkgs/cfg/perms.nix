{ lib, pkgs, vars }:
''
        # Git runs here as root, so pulled/created files are root-owned; this fixes ownership under ${vars.configPath}.
        # Only wrong entries are touched: chown bumps ctime -> git rescans every file, and the path
        # unit below would retrigger itself forever.
        def "main perms" [] {
            let firstUser = "${builtins.head vars.users}"
            let users = [ ${lib.concatMapStringsSep " " (u: "\"${u}\"") vars.users} ]
            let foreign = (foreignHmDirs)
            let prunes = ($foreign | each { |d| [ "-path" $d "-prune" "-o" ] } | flatten)
            for repo in ([ "${vars.configPath}/common" ] ++ (hostRepos)) {
                if not ($repo | path exists) { continue }  # first boot: repos may not exist yet
                let hm = $"($repo)/hm"
                if ($hm | path exists) {
                    ^${pkgs.findutils}/bin/find $repo -path $hm -prune -o ! -user root -exec ${pkgs.coreutils}/bin/chown -h root {} +
                    # hm belongs to root (1755) with an ACL for the first user; the sticky bit stops anyone
                    # from renaming hm/root — `mv hm/root x; mkdir hm/root` would feed root someone else's
                    # code on the next passwordless reconf. The ACL's mask shows up as group bits in stat
                    # (hm looks 1775), so hm is excluded from the chmod steps below.
                    if ((^${pkgs.coreutils}/bin/stat -c %U $hm | complete).stdout | str trim) != "root" { ^${pkgs.coreutils}/bin/chown root $hm }
                    if not (((^${pkgs.coreutils}/bin/stat -c %a $hm | complete).stdout | str trim) in [ "1755" "1775" ]) { ^${pkgs.coreutils}/bin/chmod 1755 $hm }
                    let wantAcl = [ "user::rwx" $"user:($firstUser):rwx" "group::r-x" "mask::rwx" "other::r-x" ] | str join "\n"
                    if ((^${pkgs.acl}/bin/getfacl -cp $hm | complete).stdout | str trim) != $wantAcl { ^${pkgs.acl}/bin/setfacl -b -m $"mask::rwx,u:($firstUser):rwx" $hm }
                    for dir in (^${pkgs.findutils}/bin/find $hm -mindepth 1 -maxdepth 1 -type d | lines) {
                        if ($foreign | any { |d| $d == $dir }) { continue }
                        let name = ($dir | path basename)
                        # files root evaluates must not be user-writable: update/reconf run without a
                        # password, that would be a passwordless path to root
                        let owner = if $name == "root" { "root" } else if ($users | any { |u| $u == $name }) { $name } else { $firstUser }
                        ^${pkgs.findutils}/bin/find $dir ! -user $owner -exec ${pkgs.coreutils}/bin/chown -h $owner {} +
                    }
                    ^${pkgs.findutils}/bin/find $hm -mindepth 1 -maxdepth 1 ! -type d ! -user $firstUser -exec ${pkgs.coreutils}/bin/chown -h $firstUser {} +
                } else {
                    ^${pkgs.findutils}/bin/find $repo ! -user root -exec ${pkgs.coreutils}/bin/chown -h root {} +
                }
                # modes: readable by all (dirs need +x to enter), executable stays as git has it,
                # write only by the owner, no setuid/setgid (foreign dirs are pruned: never touched)
                ^${pkgs.findutils}/bin/find $repo ...$prunes ! -type l ! -path $hm -perm /022 -exec ${pkgs.coreutils}/bin/chmod go-w {} +
                ^${pkgs.findutils}/bin/find $repo ...$prunes ! -type l ! -path $hm -perm /6000 -exec ${pkgs.coreutils}/bin/chmod ug-s {} +
                ^${pkgs.findutils}/bin/find $repo ...$prunes -type d ! -path $hm ! -perm -555 -exec ${pkgs.coreutils}/bin/chmod a+rx {} +
                ^${pkgs.findutils}/bin/find $repo ...$prunes -type f ! -path $hm ! -perm -444 -exec ${pkgs.coreutils}/bin/chmod a+r {} +
            }
            for d in $foreign {
                reportProblem "cfg perms" $"foreign hm dir ($d): fix its owner and run cfg perms again" --quiet
            }
            if ($foreign | is-not-empty) { exit 1 }
        }
''
