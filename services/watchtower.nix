# Watchtower — checks all running containers for updated images daily and
# removes superseded images.
{ ... }:

{
  virtualisation.oci-containers.containers.watchtower = {
    image = "containrrr/watchtower:latest";
    volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ];
    environment = {
      WATCHTOWER_CLEANUP = "true";
      WATCHTOWER_POLL_INTERVAL = "86400";
      WATCHTOWER_INCLUDE_RESTARTING = "true";
    };
  };
}
