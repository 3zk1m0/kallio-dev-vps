# Single edit point for everything deployment-specific.
{
  # Public DNS (see README "DNS setup" — one A record, everything else CNAMEs)
  baseDomain = "kallio.dev";                # Pangolin resources live under *.kallio.dev
  dashboardDomain = "pangolin.kallio.dev";  # Pangolin UI + tunnel endpoint
  ntfyDomain = "ntfy.kallio.dev";           # push notifications

  # Let's Encrypt expiry/problem notifications
  acmeEmail = "admin@kallio.dev";

  # Root SSH keys: the GitHub Actions deploy key plus your personal key
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDxpFdDaKOheemL7LYPaEv0qrhu9eQpAlHG7GhJTLL4p deploy@github-actions"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1Sd29s/9BMJeUy5E3JdJZJEyovXgn0VCem5vPpd/yy tietokettu-vps"
  ];

  # This repo's flake — the VPS pulls it nightly for auto-upgrades
  autoUpgradeFlake = "github:3zk1m0/kallio-dev-vps#vps";
}
