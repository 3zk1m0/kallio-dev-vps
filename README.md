# Disposable NixOS VPS Gateway

A fully declarative, throwaway public ingress node. It reverse-proxies Jellyfin
and other services from a home NAS to the internet over a Tailscale /
WireGuard (Pangolin) tunnel. If the VPS dies or the provider annoys you,
spin up a fresh instance anywhere and reinstall in ~5 minutes — nothing of
value lives on the box.

```
Internet ──▶ VPS (this repo)                    Home network
             ├── :80/:443  reverse proxy ─────▶ NAS: Jellyfin, services
             ├── :51820/udp Pangolin/WireGuard ─┘ (over Tailscale/WG tunnel)
             └── Watchtower keeps containers fresh
```

## Repository layout

| File | Purpose |
|---|---|
| `flake.nix` | Flake entry point; switch `system` between `x86_64-linux` / `aarch64-linux` |
| `vars.nix` | **Single edit point**: domains, ACME email, SSH keys, repo flake URL |
| `disk-config.nix` | disko partitioning: hybrid BIOS+EFI boot, ext4 root |
| `configuration.nix` | Host OS: SSH keys only, fail2ban, firewall, auto-upgrades, Docker, Tailscale, zram + 2 GB `/var/swapfile` |
| `services/pangolin.nix` | Pangolin ingress stack: dashboard + Gerbil (WireGuard) + Traefik (TLS/routing) |
| `services/ntfy.nix` | Push notification server; provisions a write-only `alerter` login for local services |
| `services/uptime-kuma.nix` | Uptime monitoring + alerting (via ntfy) |
| `services/watchtower.nix` | Daily container image updates |
| `services/bandwidth-alert.nix` | vnstat + daily check; pushes to ntfy past 70% of the provider's monthly transfer cap |
| `services/backup.nix` | `vps-backup`: streams the non-declarative state as a tarball for the NAS to pull |
| `.github/workflows/deploy.yml` | CI: eval check on PRs, one-time `nixos-anywhere` bootstrap, `nixos-rebuild` on every push |
| `.github/workflows/update-flake-lock.yml` | Weekly PR bumping `flake.lock` — this is what actually ships OS updates |
| `.sops.yaml` / `secrets/` | sops-nix encrypted secrets (Tailscale auth key) — optional but recommended |

## What the system does for you automatically

- **OS upgrades** daily at 04:00 (`system.autoUpgrade` pulls this repo's flake; reboots only within the 04:00–05:00 window). Note: the nightly job rebuilds against the committed `flake.lock`, so updates actually arrive when you merge the weekly `update-flake.lock` PR.
- **Nix garbage collection** weekly (`--delete-older-than 14d`) + store optimisation — keeps small VPS SSDs from filling up
- **Docker image updates** daily via Watchtower with `--cleanup` (old images removed)
- **Docker prune** weekly; container logs rotated (10 MB × 3 per container); journal capped at 200 MB
- **OOM protection**: zram swap absorbs pressure first, with a 2 GB `/var/swapfile` as backstop — survives Nix builds on 1–2 GB RAM instances
- **Bandwidth alerting**: vnstat records monthly usage; a daily timer pushes to ntfy once the month's total passes 70% of the cap set in `services/bandwidth-alert.nix`
- **SSH brute-force protection** via fail2ban

---

## 1. Prepare the repo

1. Fork/clone this repo and push it to GitHub.
2. Generate a dedicated deploy key (no passphrase):

   ```bash
   ssh-keygen -t ed25519 -f ./deploy_key -C "deploy@github-actions" -N ""
   ```

3. Fill in `vars.nix`: your domains, ACME email, the contents of
   `deploy_key.pub` (plus your personal public key), and this repo's flake
   URL (`github:<your-user>/<this-repo>#vps`) for nightly self-updates.
4. In `flake.nix`, set `system` to match your VPS (`x86_64-linux` or
   `aarch64-linux`).
5. In `disk-config.nix`, confirm the disk device. On Netcup/UpCloud KVM it is
   normally `/dev/vda`; boot the provider's rescue system and run `lsblk` if
   unsure.

## 2. Set up GitHub Secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `VPS_IP` | Public IPv4 of the VPS |
| `VPS_SSH_KEY` | Contents of the **private** `deploy_key` file (the full `-----BEGIN OPENSSH PRIVATE KEY-----` block) |
| `SOPS_AGE_KEY` *(optional)* | The age private key (`AGE-SECRET-KEY-...`) — planted on the VPS during bootstrap so sops secrets decrypt from first boot |
| `VPS_KNOWN_HOSTS` *(optional)* | Output of `ssh-keyscan <VPS_IP>` after bootstrap — pins the host key for deploys instead of trust-on-first-use |
| `FLAKE_UPDATE_TOKEN` *(optional)* | Fine-grained PAT (this repo; contents + pull-requests: read/write) — lets the weekly `flake.lock` PR trigger CI and auto-merge. Without it the PR opens but needs a manual merge |

Then delete the local `deploy_key` file or store it in a password manager —
it must never be committed.

> **Repo settings:** enable *Settings → Actions → General → Allow GitHub
> Actions to create and approve pull requests*, or the weekly
> `update-flake.lock` workflow can't open its PR.

## 2b. Secrets (optional, recommended): zero-touch Tailscale join

Without this, everything works but you must run `tailscale up` manually after
each (re)install. With it, the node joins the tailnet on first boot.

```bash
# 1. Generate an age keypair; note the printed "age1..." public key
nix shell nixpkgs#age -c age-keygen -o key.txt

# 2. Put the public key into .sops.yaml (replace the placeholder)

# 3. Create a reusable, pre-approved auth key in the Tailscale admin console
#    (Settings → Keys), then create the encrypted secrets file:
mkdir -p secrets
nix shell nixpkgs#sops -c sops secrets/secrets.yaml
#    In the editor, add:   tailscale-authkey: tskey-auth-...

# 4. Commit .sops.yaml and secrets/secrets.yaml (they're safe — encrypted).
#    Store the key.txt contents as the SOPS_AGE_KEY GitHub secret and in your
#    password manager, then delete key.txt. NEVER commit it.
```

`configuration.nix` detects `secrets/secrets.yaml` automatically — no config
changes needed. The bootstrap workflow plants the age key at
`/var/lib/sops-nix/key.txt` on the target via `--extra-files`.

## 3. Bootstrap with nixos-anywhere

The target must be reachable as `root` over SSH running *any* Linux — the
provider's stock Debian/Ubuntu image or a rescue system is fine
(nixos-anywhere kexecs into a NixOS installer, then disko wipes and
partitions the disk).

**Option A — from GitHub Actions (recommended):**

1. Make sure the deploy public key is accepted by the *current* OS on the VPS
   (most providers let you inject an SSH key at instance creation — use
   `deploy_key.pub`).
2. Go to **Actions → Deploy NixOS VPS → Run workflow**, tick **bootstrap**,
   and run it. ⚠️ This **erases the target disk**.

**Option B — from your workstation:**

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps \
  --build-on-remote \
  root@<VPS_IP>
```

`--build-on-remote` builds on the VPS itself, so this works from any machine
(including macOS and CI runners) and regardless of the target architecture.

After the reboot: `ssh root@<VPS_IP>` should log you into NixOS.

## 4. Post-install: join the tailnet

If you set up sops secrets (step 2b), the node joined the tailnet at first
boot — nothing to do. Otherwise, one-time login:

```bash
ssh root@<VPS_IP> tailscale up
# open the printed URL, authorise the node in your tailnet
```

Your NAS (also on the tailnet) is now reachable from the VPS by its Tailscale
IP/MagicDNS name — point your reverse proxy upstreams at it.

**Exit node:** the VPS advertises itself as a Tailscale exit node
(`--advertise-exit-node`), so any device on your tailnet can route all its
internet traffic through the VPS's public IP. Approve it once in the
Tailscale admin console (machine → *Edit route settings* → *Use as exit
node*), or add an ACL `autoApprovers` rule to keep reinstalls zero-touch:

```jsonc
"autoApprovers": { "exitNode": ["your-tailnet-login@example.com"] }
```

Keep in mind exit-node traffic counts against the VPS provider's bandwidth
quota, on top of the media streaming it already proxies.

Optionally, now pin the host key for future deploys:

```bash
ssh-keyscan <VPS_IP>   # → store output as the VPS_KNOWN_HOSTS secret
```

## 5. Ongoing deploys & updates

Push to `main`. The `check` job evaluates the full system first; the `deploy`
job then runs
`nixos-rebuild switch --flake .#vps --target-host root@$VPS_IP --build-host root@$VPS_IP`,
building on the VPS and activating the new generation in place — no
reinstall, no downtime. Independently, the VPS also pulls this repo itself
every night at 04:00 via `system.autoUpgrade`.

**OS updates flow:** every Monday the `update-flake.lock` workflow opens a PR
bumping `flake.lock` (new nixpkgs = kernel/security updates), enables
auto-merge on it, and once the CI `check` job passes it merges itself — the
push-triggered deploy (or the nightly auto-upgrade) then ships it. Fully
hands-off, with CI as the gate. For auto-merge to work, set up once:

1. The `FLAKE_UPDATE_TOKEN` secret (see the secrets table) — without it the
   PR can't trigger CI.
2. *Settings → General → Allow auto-merge*: enabled.
3. A branch ruleset on `main` requiring the `check` status check — this is
   what auto-merge waits for (and it protects your own pushes too).

If any piece is missing the workflow degrades gracefully: the PR still
opens, it just waits for a manual merge.

> `system.autoUpgrade` fetches this repo from GitHub — keep the repo
> **public**, or the VPS won't be able to pull it (private repos would need
> an access token on the box).

## 6. DNS setup for maximum portability

The trick: give the VPS **one** A/AAAA record, and point every service at it
with CNAMEs. When you replace the VPS (new provider, new IP), you update a
single record and every service follows.

| Record | Type | Value |
|---|---|---|
| `gw.example.com` | A | `<VPS_IP>` |
| `pangolin.example.com` | CNAME | `gw.example.com` |
| `ntfy.example.com` | CNAME | `gw.example.com` |
| `uptime.example.com` | CNAME | `gw.example.com` |
| `jellyfin.example.com` | CNAME | `gw.example.com` |
| `photos.example.com` | CNAME | `gw.example.com` |
| `*.example.com` (optional) | CNAME | `gw.example.com` |

Recovery procedure when the VPS dies:

1. Create a fresh instance anywhere, inject `deploy_key.pub`.
2. Update the `VPS_IP` secret; re-run the **bootstrap** workflow.
3. `tailscale up` once.
4. Point `gw.example.com` at the new IP. Done — every CNAME follows.

Keep DNS TTLs low (300s) on `gw.example.com` if you want fast cutovers.

## 7. Pangolin: expose NAS services to the internet

`services/pangolin.nix` runs the full [Pangolin](https://pangolin.net) stack:

- **pangolin** — dashboard + API (state in `/var/lib/pangolin`, SQLite)
- **gerbil** — WireGuard gateway terminating tunnels from your NAS (51820/udp)
- **traefik** — TLS (Let's Encrypt) + routing, driven dynamically by Pangolin

A random `server.secret` is generated on first boot; the only manual steps
are one-time:

1. **DNS first**: make sure `pangolin.example.com` (your `dashboardDomain`)
   resolves to the VPS *before* first boot, or the Let's Encrypt HTTP
   challenge fails.
2. Grab the setup token from the logs and register the admin account:

   ```bash
   ssh root@<VPS_IP> docker logs pangolin 2>&1 | grep -i "setup token"
   # then open https://pangolin.example.com/auth/initial-setup
   ```

3. In the dashboard, create a **Site** for your NAS — it gives you a `newt`
   ID + secret. On the NAS, run the connector (outbound-only; no ports to
   open at home):

   ```bash
   docker run -d --name newt --restart unless-stopped \
     -e PANGOLIN_ENDPOINT=https://pangolin.example.com \
     -e NEWT_ID=<id> -e NEWT_SECRET=<secret> \
     fosrl/newt:latest
   ```

4. Add **Resources** in the dashboard (e.g. `jellyfin.example.com` →
   `nas-ip:8096`). Traefik picks them up and issues certificates
   automatically — no Nix changes, no redeploys.

**State caveat:** `/var/lib/pangolin` (sites, resources, users, certs) is the
one stateful directory on this otherwise disposable box. After a reinstall
you'd redo the dashboard setup and re-register newt (~5 minutes) — or back up
that directory if you'd rather not.

## 8. ntfy: push notifications

A [ntfy](https://ntfy.sh) server runs on the VPS so alerts still arrive when
your home network is down. It is locked down by default
(`auth-default-access: deny-all`); one-time setup:

1. Set `ntfyDomain` in `vars.nix`.
2. In the Pangolin dashboard, create a **local site** (the VPS itself), then a
   resource `ntfy.example.com` → HTTP → hostname `ntfy`, port `80`.
   Skip Pangolin's own auth on this resource — ntfy brings its own, and the
   mobile apps need direct API access.
3. Create your user and an access token:

   ```bash
   ssh root@<VPS_IP>
   docker exec -it ntfy ntfy user add --role=admin sander
   docker exec -it ntfy ntfy token add sander
   ```

4. Point the ntfy iOS/Android app (or any script) at
   `https://ntfy.example.com`:

   ```bash
   curl -H "Authorization: Bearer tk_..." -d "backup finished" \
     https://ntfy.example.com/homelab
   ```

State lives in `/var/lib/ntfy` (users/tokens + message cache) — tiny, and
losing it just means re-adding a user.

## 9. Uptime Kuma: monitoring + alerts

Pangolin CE shows health status and does failover, but only the paid
editions can *notify* you. Uptime Kuma fills that gap — and because it runs
on the VPS, it can tell "Jellyfin crashed" apart from "home internet is
down".

1. Expose it via Pangolin: local site → resource `uptime.example.com` →
   HTTP → hostname `uptime-kuma`, port `3001`. Put Pangolin auth in front
   of it (or use Kuma's own login, created on first visit).
2. Add monitors: your public URLs (`https://jellyfin.example.com`) check
   the whole chain; NAS-internal addresses check the tunnel specifically.
3. Add a **ntfy notification** in Kuma (Settings → Notifications):
   server `https://ntfy.example.com`, a topic like `alerts`, and an access
   token from `docker exec -it ntfy ntfy token add sander`.
4. Optional: publish a public status page from Kuma on its own domain.

State (monitors, history) lives in `/var/lib/uptime-kuma`.

## 10. Backups: pull the state the repo can't rebuild

Almost everything here is declarative — a fresh instance plus this flake gets
you back to a working box. What a rebuild *cannot* regenerate:

| Path | What's in it |
|---|---|
| `/var/lib/pangolin/config` | Pangolin's SQLite DB (sites, resources, users), `config.yml` server secret, Gerbil's WireGuard key, `letsencrypt/acme.json` |
| `/var/lib/ntfy` | ntfy user/ACL DB + the generated `alerter` password |
| `/var/lib/uptime-kuma` | Kuma monitors, notification config, history |
| `/var/lib/vnstat` | Monthly transfer history behind the bandwidth alert |
| `/var/lib/sops-nix/key.txt` | The age key that decrypts `secrets/secrets.yaml` |

`services/backup.nix` installs a `vps-backup` command that tars those paths to
**stdout**. Nothing is stored on the VPS and no schedule runs there.

It does *not* stop the containers first. Stopping `docker-pangolin` cascades
through the `dependsOn` chain to gerbil and traefik, and all public ingress
stays down until Pangolin's API is serving again — measured at ~70 s, far too
long for a nightly job. Instead the paths are copied, then every database in
the copy is overwritten with `sqlite3 .backup` of the live file: SQLite's own
online backup, consistent under concurrent writes, ~7 s, zero downtime.

**The NAS pulls** over the tailnet — the backup host holds the keys, so the
internet-facing box needs no NAS credentials and can't reach in to wipe its own
backups. Everything lives in one directory on the redundant pool:

```
/mnt/data-hdd/backups/vps/
├── pull.sh          # ssh in, verify the gzip, rotate at 30 days, ping Kuma
├── id_ed25519       # key that may run nothing but `vps-backup`
├── known_hosts      # VPS host key, pinned
├── push-url         # optional: Uptime Kuma push URL (created by you)
└── vps-YYYY-MM-DD.tar.gz
```

Setup on TrueNAS SCALE:

1. **Dataset**: `data-hdd/backups`, with `vps/` inside it at mode 700. Keeping
   the key and script in a dataset (not `/root`) means they survive OS updates.
2. **Key**: `ssh-keygen -t ed25519 -f id_ed25519 -N "" -C truenas-vps-backup`,
   then pin the host key with
   `ssh-keyscan -t ed25519 <vps-tailnet-ip> > known_hosts`.
3. **Authorise it** in `vars.nix` `sshKeys`, prefixed so the key is useless for
   anything else — a stolen NAS key can then only re-read state the NAS already
   has, not log into the VPS:

   ```
   restrict,command="/run/current-system/sw/bin/vps-backup" ssh-ed25519 AAAA... truenas-vps-backup
   ```

   Push to deploy before the first run.
4. **Schedule**: System Settings → Advanced → Cron Jobs → Add, running
   `/mnt/data-hdd/backups/vps/pull.sh` as `root` at 03:15 daily. Leave *Hide
   Standard Output* on and *Hide Standard Error* **off**, so a failure mails
   you. Note this is NAS-local time — keep it clear of the VPS's 04:00–05:00
   **UTC** auto-upgrade/reboot window.
   Use a script, not an inline command: cron treats `%` specially, so an
   inline `date +%F` breaks.
5. **Notice when it stops**: add an Uptime Kuma monitor of type *Push* with a
   ~26 h heartbeat, and drop its URL into `push-url`. `pull.sh` curls it only
   after a verified archive lands, so ntfy pings you when a night is missed —
   including the cases a `|| notify` can never catch, like the NAS being off or
   the cron job being disabled.

Tailscale on TrueNAS runs as an app with host networking, so the host itself
gets a `tailscale0` interface — cron can reach the VPS's tailnet IP directly,
no extra routing needed.

> The archive contains the Pangolin server secret, Let's Encrypt private keys
> and the age key — treat it like a password vault export. Keep it on an
> encrypted share, `chmod 600`, and off any cloud sync you don't control.

**Restore** onto a fresh instance. Bootstrap normally (section 3), but leave DNS
alone until the very end:

```bash
# Stop everything holding the state open (pangolin cascades to gerbil + traefik)
ssh root@<new-ip> systemctl stop docker-pangolin docker-ntfy docker-uptime-kuma vnstat
ssh root@<new-ip> tar -xzf - -C / < vps-2026-01-31.tar.gz
ssh root@<new-ip> reboot
# Only now: point the pangolin.<domain> A record at the new IP (section 6)
```

The stop is not optional. Extract under a running Pangolin and its open handle
on `db.sqlite` wins — you get a corrupt database, not a restored one.

DNS goes last so the fresh box never serves a half-empty dashboard on the real
domain, and so Traefik starts from the restored `acme.json` (mode 600, which
`tar` preserves — Traefik refuses it otherwise) rather than requesting
certificates it already has.

Nothing regenerates over the top of the restore: `pangolin-setup` writes
`config.yml` only when the file is absent, so the original server secret
survives the reboot. Sites reconnect without re-enrolling — their WireGuard
keys are in the restored Pangolin DB and Gerbil's key comes back with it. The
age key is in the archive too, so sops decrypts from the next boot even if you
bootstrapped without the `SOPS_AGE_KEY` secret.

More often you want one service back on an otherwise healthy box:

```bash
systemctl stop docker-pangolin
tar -xzf vps-2026-01-31.tar.gz -C / ./var/lib/pangolin
systemctl start docker-pangolin
```

> Two caveats. The mechanics above are verified, but a **full restore has never
> been rehearsed end to end** — proving it takes a scratch instance. And
> Watchtower keeps images moving: an old database migrates forward into a newer
> Pangolin but never backward, so after a breaking major bump, pin the image to
> the version that wrote the archive.

## Later: shared login (SSO) for everything

For a single account across all services, add a self-hosted OIDC identity
provider (e.g. [Pocket ID](https://pocket-id.org), passkey-first, ~1
container) and connect it to Pangolin under **Identity Providers → Add →
Generic OIDC**. Pangolin-gated resources then share one login, and apps
with native OIDC support (Immich, Grafana, ...) can point at the same
provider. Until then, Pangolin's built-in user accounts gate resources
just fine.

## Adding services

Public-facing services from the NAS: add them as Pangolin resources (above) —
no code changes. VPS-local containers: add them under
`virtualisation.oci-containers.containers` in `configuration.nix` (join
`--network=pangolin` to expose them through Traefik) and push. Watchtower
keeps all images updated daily.
