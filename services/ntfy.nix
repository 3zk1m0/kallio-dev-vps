# ntfy — push notifications, reachable even when the home network is down.
# Expose via Pangolin: local site → resource ${vars.ntfyDomain} → http://ntfy:80
{ pkgs, vars, ... }:

let
  topic = "alerts";
  passwordFile = "/var/lib/ntfy/alerter-password";
in
{
  virtualisation.oci-containers.containers.ntfy = {
    # Rolling major tag: Watchtower pulls v2.x updates.
    image = "binwiederhier/ntfy:v2";
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

  # Local services publish as "alerter" over basic auth. The password is
  # generated on first start and lives beside the auth db, so a reinstall
  # regenerates credential and database together.
  systemd.services.ntfy-alerter = {
    after = [ "docker-ntfy.service" ];
    requires = [ "docker-ntfy.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The container needs a moment before `docker exec` works.
      Restart = "on-failure";
      RestartSec = 5;
    };
    script = ''
      pwfile=${passwordFile}
      if [ ! -s "$pwfile" ]; then
        (umask 077; head -c 24 /dev/urandom | base64 > "$pwfile")
      fi
      pw=$(cat "$pwfile")

      docker exec -e NTFY_PASSWORD="$pw" ntfy ntfy user add --role=user alerter ||
        docker exec -e NTFY_PASSWORD="$pw" ntfy ntfy user change-pass alerter
      docker exec ntfy ntfy access alerter ${topic} write-only
    '';
  };

  systemd.services.docker-ntfy = {
    after = [ "init-pangolin-network.service" ];
    requires = [ "init-pangolin-network.service" ];
  };
}
