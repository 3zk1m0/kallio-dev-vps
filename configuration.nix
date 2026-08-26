{ config, lib, pkgs, modulesPath, vars, ... }:

let
  # Secrets are optional: the system builds and deploys before
  # secrets/secrets.yaml exists; once it does, sops-nix kicks in.
  hasSecrets = builtins.pathExists ./secrets/secrets.yaml;
in
{
  imports = [
    # Sensible defaults for QEMU/KVM guests (Netcup, UpCloud, Hetzner, ...)
    (modulesPath + "/profiles/qemu-guest.nix")
    ./services/watchtower.nix
    ./services/pangolin.nix
    ./services/ntfy.nix
    ./services/uptime-kuma.nix
  ];

  ###########################################################################
  # Boot — hybrid BIOS/EFI GRUB (pairs with disk-config.nix)
  ###########################################################################
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    # Install to the EFI fallback path so the VPS boots without NVRAM entries
    # (cloud firmware frequently loses/ignores them).
    efiInstallAsRemovable = true;
    # BIOS install device is added automatically by disko (EF02 partition).
  };

  boot.initrd.availableKernelModules = [
    "ata_piix" "uhci_hcd" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod"
  ];

  services.qemuGuest.enable = true;
  networking.hostName = "vps-gateway";
  networking.useDHCP = lib.mkDefault true;

  ###########################################################################
  # Swap — 2 GB swap file to protect 1–2 GB RAM instances from OOM
  ###########################################################################
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 2048; # MiB — created automatically on first boot
    }
  ];
  # Compressed RAM swap absorbs memory pressure first; the disk swap file
  # is the true OOM backstop.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
  boot.kernel.sysctl."vm.swappiness" = 10;

  ###########################################################################
  # SSH — root with keys only
  ###########################################################################
  services.openssh = {
    enable = true;
    # SSH is tailnet-only: no public port 22. CI deploys join the tailnet
    # as ephemeral nodes; recovery without Tailscale = provider VNC console.
    openFirewall = false;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = vars.sshKeys;

  services.fail2ban.enable = true;

  ###########################################################################
  # Secrets (sops-nix) — optional until secrets/secrets.yaml exists
  ###########################################################################
  sops = lib.mkIf hasSecrets {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets."tailscale-authkey" = { };
  };

  ###########################################################################
  # Firewall
  ###########################################################################
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      80   # HTTP (ACME challenges / redirect)
      443  # HTTPS
    ];
    allowedUDPPorts = [
      51820 # Pangolin / WireGuard tunnel to the home NAS
    ];
    # Anything arriving over the tailnet is trusted (Jellyfin backend, etc.)
    trustedInterfaces = [ "tailscale0" ];
  };

  ###########################################################################
  # Automatic maintenance — upgrades, GC, store optimisation
  ###########################################################################
  system.autoUpgrade = {
    enable = true;
    flake = vars.autoUpgradeFlake;
    dates = "04:00";
    randomizedDelaySec = "15min";
    allowReboot = true; # disposable gateway — reboot for kernel updates is fine
    rebootWindow = {
      lower = "04:00";
      upper = "05:00";
    };
  };

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    optimise.automatic = true;
  };

  ###########################################################################
  # Application runtime — Docker + Watchtower + Tailscale
  ###########################################################################
  virtualisation.docker = {
    enable = true;
    # Container logs go to the journald driver (NixOS default), which the
    # journal's own 200 MB cap already rotates — no per-container log-opts.
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Containers live in services/*.nix; NAS services are added via the
  # Pangolin dashboard, not here.
  virtualisation.oci-containers.backend = "docker";

  services.tailscale = {
    enable = true;
    # "both": reach NAS subnet routes as a client AND enable the IP
    # forwarding sysctls needed to serve as an exit node.
    useRoutingFeatures = "both";
    # Requires approval in the Tailscale admin console (or an ACL
    # autoApprovers rule) before other nodes can use it.
    extraUpFlags = [ "--advertise-exit-node" ];
    # With secrets in place the node joins the tailnet on first boot —
    # no manual `tailscale up` needed after a reinstall.
    authKeyFile = lib.mkIf hasSecrets config.sops.secrets."tailscale-authkey".path;
  };

  ###########################################################################
  # Misc
  ###########################################################################
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    curl
  ];

  # Cap the journal so logs can't eat the SSD.
  services.journald.extraConfig = "SystemMaxUse=200M";

  time.timeZone = "UTC";

  # Do not change after first install.
  system.stateVersion = "25.05";
}
