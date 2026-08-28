# Backup — the handful of files that aren't in git and can't be regenerated:
# Pangolin's SQLite + server secret, Let's Encrypt certs, Gerbil's WireGuard
# key, the ntfy/Kuma databases, vnstat history and the sops age key.
#
# Pull-only by design: the NAS reaches in over the tailnet and streams the
# archive to itself, so this public-facing box holds no NAS credentials.
#
#   ssh root@vps-gateway vps-backup > vps-$(date +%F).tar.gz
{ lib, pkgs, ... }:

let
  paths = lib.concatStringsSep " " [
    "var/lib/pangolin"
    "var/lib/ntfy"
    "var/lib/uptime-kuma"
    "var/lib/vnstat"
    "var/lib/sops-nix"
  ];
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "vps-backup";
      runtimeInputs = with pkgs; [ coreutils findutils gnutar gzip sqlite ];
      text = ''
        cd /
        staging=$(mktemp -d -p /var/tmp vps-backup.XXXXXX)
        trap 'rm -rf "$staging"' EXIT

        tar -cf - ${paths} | tar -xf - -C "$staging"

        # Stopping the containers for a consistent copy is not an option: it
        # cascades through Pangolin's dependsOn chain and drops all public
        # ingress for ~a minute. Overwrite each copied database with sqlite's
        # own online backup of the live one instead — consistent, no downtime.
        find ${paths} \( -name '*.db' -o -name '*.sqlite' \) -print0 |
          while IFS= read -r -d "" db; do
            sqlite3 "/$db" ".backup '$staging/$db'"
          done

        # Sidecars belong to a database's live writer, never to a snapshot.
        find "$staging" \( -name '*-wal' -o -name '*-shm' \) -delete

        tar -czf - -C "$staging" .
      '';
    })
  ];
}
