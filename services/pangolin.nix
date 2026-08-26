# Pangolin stack — self-hosted tunneled reverse proxy (https://pangolin.net).
#
# Mirrors the official docker-compose (Pangolin 1.21.x):
#   pangolin  dashboard + API (state in /var/lib/pangolin/config, SQLite)
#   gerbil    WireGuard gateway; owns the published ports
#   traefik   TLS termination + routing, runs inside gerbil's network namespace
#
# Sites/resources are managed in the dashboard, which pushes routes to
# Traefik dynamically — adding a service needs no changes here.
#
# Other VPS-local containers can be exposed through Traefik by joining the
# "pangolin" docker network (extraOptions = [ "--network=pangolin" ]) and
# ordering after init-pangolin-network.service — see ntfy.nix.

{ config, lib, pkgs, vars, ... }:

let
  badgerVersion = "v1.5.0"; # Traefik auth-middleware plugin, released with Pangolin

  dataDir = "/var/lib/pangolin";

  pangolinConfigTemplate = pkgs.writeText "pangolin-config.yml" ''
    gerbil:
        start_port: 51820
        base_endpoint: "${vars.dashboardDomain}"

    app:
        dashboard_url: "https://${vars.dashboardDomain}"
        log_level: "info"
        telemetry:
            anonymous_usage: false

    domains:
        domain1:
            base_domain: "${vars.baseDomain}"

    server:
        secret: "@SECRET@"
        cors:
            origins: ["https://${vars.dashboardDomain}"]
            methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]
            allowed_headers: ["X-CSRF-Token", "Content-Type"]
            credentials: false

    flags:
        require_email_verification: false
        disable_signup_without_invite: true
        disable_user_create_org: false
        allow_raw_resources: true
  '';

  traefikStatic = pkgs.writeText "traefik_config.yml" ''
    providers:
      http:
        endpoint: "http://pangolin:3001/api/v1/traefik-config"
        pollInterval: "5s"
      file:
        filename: "/etc/traefik/dynamic_config.yml"

    experimental:
      plugins:
        badger:
          moduleName: "github.com/fosrl/badger"
          version: "${badgerVersion}"

    log:
      level: "INFO"
      format: "common"

    certificatesResolvers:
      letsencrypt:
        acme:
          httpChallenge:
            entryPoint: web
          email: "${vars.acmeEmail}"
          storage: "/letsencrypt/acme.json"
          caServer: "https://acme-v02.api.letsencrypt.org/directory"

    entryPoints:
      web:
        address: ":80"
      websecure:
        address: ":443"
        transport:
          respondingTimeouts:
            readTimeout: "30m"
        http3:
          advertisedPort: 443
        http:
          tls:
            certResolver: "letsencrypt"
          encodedCharacters:
            allowEncodedSlash: true
            allowEncodedQuestionMark: true

    serversTransport:
      insecureSkipVerify: true

    ping:
      entryPoint: "web"
  '';

  traefikDynamic = pkgs.writeText "dynamic_config.yml" ''
    http:
      middlewares:
        badger:
          plugin:
            badger:
              disableForwardAuth: true
        redirect-to-https:
          redirectScheme:
            scheme: https

      routers:
        main-app-router-redirect:
          rule: "Host(`${vars.dashboardDomain}`)"
          service: next-service
          entryPoints:
            - web
          middlewares:
            - redirect-to-https
            - badger

        next-router:
          rule: "Host(`${vars.dashboardDomain}`) && !PathPrefix(`/api/v1`)"
          service: next-service
          entryPoints:
            - websecure
          middlewares:
            - badger
          tls:
            certResolver: letsencrypt

        api-router:
          rule: "Host(`${vars.dashboardDomain}`) && PathPrefix(`/api/v1`)"
          service: api-service
          entryPoints:
            - websecure
          middlewares:
            - badger
          tls:
            certResolver: letsencrypt

        ws-router:
          rule: "Host(`${vars.dashboardDomain}`)"
          service: api-service
          entryPoints:
            - websecure
          middlewares:
            - badger
          tls:
            certResolver: letsencrypt

      services:
        next-service:
          loadBalancer:
            servers:
              - url: "http://pangolin:3002"

        api-service:
          loadBalancer:
            servers:
              - url: "http://pangolin:3000"

    tcp:
      serversTransports:
        pp-transport-v1:
          proxyProtocol:
            version: 1
        pp-transport-v2:
          proxyProtocol:
            version: 2
  '';

  traefikConfigDir = pkgs.runCommand "traefik-config" { } ''
    mkdir -p $out
    cp ${traefikStatic} $out/traefik_config.yml
    cp ${traefikDynamic} $out/dynamic_config.yml
  '';
in
{
  networking.firewall.allowedUDPPorts = [
    443   # HTTP/3 (QUIC)
    21820 # Gerbil relay
  ];

  # First boot: create the data dir and generate the server secret.
  systemd.services.pangolin-setup = {
    description = "Generate Pangolin config on first boot";
    wantedBy = [ "multi-user.target" ];
    before = [ "docker-pangolin.service" ];
    requiredBy = [ "docker-pangolin.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p ${dataDir}/config/letsencrypt
      chmod 700 ${dataDir}
      if [ ! -f ${dataDir}/config/config.yml ]; then
        secret=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        ${pkgs.gnused}/bin/sed "s|@SECRET@|$secret|" \
          ${pangolinConfigTemplate} > ${dataDir}/config/config.yml
        chmod 600 ${dataDir}/config/config.yml
      fi
    '';
  };

  # User-defined bridge so the containers resolve each other by name
  # (the default docker bridge has no DNS).
  systemd.services.init-pangolin-network = {
    description = "Create pangolin docker network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect pangolin >/dev/null 2>&1 || \
        ${pkgs.docker}/bin/docker network create pangolin
    '';
  };

  systemd.services.docker-pangolin = {
    after = [ "init-pangolin-network.service" ];
    requires = [ "init-pangolin-network.service" ];
  };
  systemd.services.docker-gerbil = {
    after = [ "init-pangolin-network.service" ];
    requires = [ "init-pangolin-network.service" ];
  };

  virtualisation.oci-containers.containers = {
    pangolin = {
      # Rolling patch tag: Watchtower pulls 1.21.x patches, minor bumps are manual.
      image = "fosrl/pangolin:1.21";
      volumes = [ "${dataDir}/config:/app/config" ];
      extraOptions = [ "--network=pangolin" ];
    };

    gerbil = {
      # Gerbil publishes no rolling tags — bump manually alongside badgerVersion.
      image = "fosrl/gerbil:1.5.0";
      dependsOn = [ "pangolin" ];
      cmd = [
        "--reachableAt=http://gerbil:3004"
        "--generateAndSaveKeyTo=/var/config/key"
        "--remoteConfig=http://pangolin:3001/api/v1/"
      ];
      volumes = [ "${dataDir}/config:/var/config" ];
      ports = [
        "51820:51820/udp"
        "21820:21820/udp"
        "80:80"
        "443:443"
        "443:443/udp"
      ];
      extraOptions = [
        "--network=pangolin"
        "--cap-add=NET_ADMIN"
        "--cap-add=SYS_MODULE"
      ];
    };

    traefik = {
      image = "traefik:v3.7";
      dependsOn = [ "pangolin" "gerbil" ];
      cmd = [ "--configFile=/etc/traefik/traefik_config.yml" ];
      volumes = [
        "${traefikConfigDir}:/etc/traefik:ro"
        "${dataDir}/config/letsencrypt:/letsencrypt"
      ];
      # Share gerbil's network namespace — published ports live on gerbil.
      extraOptions = [ "--network=container:gerbil" ];
    };
  };
}
