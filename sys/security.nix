{ config, lib, pkgs, vars, com, cur, ... }:
{
    security = {
#         polkit = {
#             enable = true;
#             extraConfig = ''
#                 polkit.addRule((action, subject) => {
#                     if (action.id == "org.freedesktop.policykit.exec") {
#                         return polkit.Result.AUTH_ADMIN;
#                     }
#                 });
#             '';
#         };
        sudo = {
            enable = true;
            extraConfig = ''
                # No credential cache: every sudo that needs a password asks for it (cfg confirms a rewritten history this way)
                Defaults timestamp_timeout=0
                # Enable sudo without password for mrChest
                "mrChest" ALL=(ALL) NOPASSWD: ALL
            '';
        };
    };
}
