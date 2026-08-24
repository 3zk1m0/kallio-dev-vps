# ntfy — push notifications, reachable even when the home network is down.
# Expose via Pangolin: local site → resource ${vars.ntfyDomain} → http://ntfy:80
{ vars, ... }:

{
  virtualisation.oci-containers.containers.ntfy = {
    image = "binwiederhier/ntfy:latest";
    cmd = [ "serve" ];
    environment = {
      NTFY_BASE_URL = "https://${vars.ntfyDomain}";
      NTFY_BEHIND_PROXY = "true";
      NTFY_CACHE_FILE = "/var/lib/ntfy/cache.db";
      NTFY_AUTH_FILE = "/var/lib/ntfy/auth.db";
      # Closed by default — create users with:
      #   docker exec -it ntfy ntfy user add --role=admin <name>
      NTFY_AUTH_DEFAULT_ACCESS = "deny-all";
      NTFY_ENABLE_LOGIN = "true";
    };
    volumes = [ "/var/lib/ntfy:/var/lib/ntfy" ];
    # Join the pangolin network so Traefik can reach it by name.
    extraOptions = [ "--network=pangolin" ];
  };

  systemd.tmpfiles.rules = [ "d /var/lib/ntfy 0700 root root -" ];

  systemd.services.docker-ntfy = {
    after = [ "init-pangolin-network.service" ];
    requires = [ "init-pangolin-network.service" ];
  };
}
