{ config, lib, pkgs, vars, com, cur, ... }: {
    powerManagement.enable = true;
    # Hibernate after 30 min with lid closed
    services.logind.settings.Login = {
        HandlePowerKey = "hibernate";
        HandlePowerKeyLongPress = "poweroff";
        HandleLidSwitch = "suspend-then-hibernate"; # Suspend first, then hibernate when the lid is closed
    };
    systemd.sleep.settings.Sleep.HibernateDelaySec = "30m"; # Fixed delay instead of the battery-discharge estimate
}
