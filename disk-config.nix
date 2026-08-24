# Declarative partitioning via disko.
#
# Layout (GPT, hybrid BIOS + EFI boot — works on Netcup/UpCloud regardless of
# whether the instance boots legacy or UEFI):
#
#   1M   EF02  BIOS boot partition (GRUB embedding area for legacy boot on GPT)
#   512M EF00  ESP, vfat, mounted at /boot
#   rest       ext4 root at /
#
# Swap is a 2 GB file at /var/swapfile, declared in configuration.nix
# (swapDevices) — NixOS creates it on first boot, keeping the disk layout
# here purely about partitions.

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # virtio disk name on Netcup/UpCloud/Hetzner KVM guests.
        # Check with `lsblk` on the rescue system; use /dev/sda for SCSI/SATA.
        device = "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # BIOS boot partition — disko wires this disk into boot.loader.grub.devices
            };
            esp = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
