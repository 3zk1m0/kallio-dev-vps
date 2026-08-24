# Uptime Kuma — monitoring from outside the home network. Pangolin CE shows
# health but can't notify; Kuma alerts via ntfy when something dies.
# Expose via Pangolin: local site → uptime.<baseDomain> → http://uptime-kuma:3001
{ ... }:

{
  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:2";
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
    extraOptions = [ "--network=pangolin" ];
  };

  systemd.tmpfiles.rules = [ "d /var/lib/uptime-kuma 0700 root root -" ];

  systemd.services.docker-uptime-kuma = {
    after = [ "init-pangolin-network.service" ];
    requires = [ "init-pangolin-network.service" ];
  };
}
