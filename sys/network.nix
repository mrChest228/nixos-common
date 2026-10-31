{ config, lib, pkgs, vars, com, cur, ... }:
{
    networking = {
        #TODO: hosts with My server (if the Internet or electricy will be disabled (for local network))
        networkmanager = {
            enable = true;
            dns = "none"; # Don't use default dns from my router. Only my own dns (unbound below)
            connectionConfig = {
                "ipv6.ip6-privacy" = 2;        # Use random-generated IP-adresses (static IP continue working)
            };
        };
        useDHCP = false;
        dhcpcd.enable = false;
        resolvconf.enable = false;
    };
    # Everybody asks the local unbound. Nobody else writes this file: resolved and resolvconf are off,
    # NetworkManager runs with rc-manager=unmanaged
    environment.etc."resolv.conf".text = ''
        nameserver ::1
        nameserver 127.0.0.1
        options edns0 trust-ad
    '';
    services.unbound = {
        enable = true;
        resolveLocalQueries = false; # Would turn resolvconf back on; resolv.conf is written above instead
        # DNSSEC is on: the module keeps the root trust anchor (auto-trust-anchor-file), unbound validates every answer itself
        settings = {
            server = {
                qname-minimisation = true; # Upstream sees only the labels it needs
                aggressive-nsec = true;    # Answer "no such name" from DNSSEC proofs already in cache
                prefetch = true;           # Refresh popular records before they expire
                serve-expired = true;      # Answer from cache while the network is down
                serve-expired-ttl = 86400;
                hide-identity = true;
                hide-version = true;
            };
            # Every query goes to these over TLS (port 853), the name after # is checked against the certificate.
            # unbound picks the fastest of them by measured latency, not by list order
            forward-zone = [
                {
                    name = ".";
                    forward-tls-upstream = true;
                    forward-addr = [
                        "2606:4700:4700::1111#cloudflare-dns.com"
                        "1.1.1.1#cloudflare-dns.com"
                        "2001:4860:4860::8888#dns.google"
                        "8.8.8.8#dns.google"
                        "2606:4700:4700::1001#cloudflare-dns.com"
                        "1.0.0.1#cloudflare-dns.com"
                    ];
                }
            ] ++ lib.optional config.services.tailscale.enable {
                name = "ts.net."; # MagicDNS names (server.<tailnet>.ts.net) are answered by the running tailscaled
                forward-addr = [ "100.100.100.100" ];
            };
        };
    };
    boot.kernel.sysctl = {
        # Network speed up
        "net.core.default_qdisc" = "fq";
        "net.ipv4.tcp_congestion_control" = "bbr";
        "net.ipv4.tcp_ecn" = 1;
    };
}
