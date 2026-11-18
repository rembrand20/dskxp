# dskxp

Grow LVM storage on Linux after you enlarged a disk (Proxmox, VMware, Hyper-V,
KVM, ...) or added a new one — from a simple menu in the shell.

```
sudo dskxp
```

1. Enlarge the virtual disk in your hypervisor, or add a disk.
2. Start `dskxp`. It rescans the disks and shows what changed.
3. It lists the free space it found and your logical volumes with their mount
   points and usage.
4. Pick the volume (mount point) that needs space, where the space should come
   from and how much (`20G`, `50%`, `all`).
5. dskxp shows **every command it will run**. Nothing changes until you confirm.

## What it can do

| Situation | What dskxp does |
|---|---|
| Disk grew, PV is the last partition | rescan → (GPT: move backup header) → grow partition → `pvresize` |
| Debian-style MBR: PV in a logical partition (`sda5` inside `sda2`) | grow the extended partition, then the logical one |
| PV on the whole disk (no partition table) | rescan → `pvresize` |
| PV on LUKS (`/dev/mapper/...`) | grow partition → `cryptsetup resize` → `pvresize` |
| PV on mdraid (RAID 1/4/5/6/10) | grow the member partitions → `mdadm --grow --size=max` → `pvresize` |
| Unallocated space elsewhere on a disk | new partition (type Linux LVM) → `pvcreate` → `vgextend` |
| New empty disk / unused partition / unused PV | `pvcreate` → `vgextend` (or `vgcreate` for a new VG) |
| Extend a logical volume | `lvextend` + grow the filesystem: ext2/3/4 (`resize2fs`), XFS (`xfs_growfs`), btrfs, swap (keeps its UUID), LUKS on top of the LV |
| New logical volume | `lvcreate` → `mkfs` (ext4/xfs/btrfs/swap) → mount point → `/etc/fstab` (by UUID) |
| Thin pools (e.g. Proxmox `pve/data`) | `lvextend` of the pool |

## Safety

- Shows a plan with the exact commands first; `--dry-run` only shows it.
- Backs up the partition table of every disk it touches to
  `/var/backups/dskxp/<disk>-<time>.sfdisk` (restore: `sfdisk /dev/sdX < file`).
  LVM keeps its own metadata history in `/etc/lvm/archive`.
- Backs up `/etc/fstab` before editing it.
- Logs every command and its output to `/var/log/dskxp.log`.
- Only grows, never shrinks. Stops at the first failing step.
- Never offers disks or partitions that contain a filesystem, a signature, are
  mounted or are used by something else.
- Warns about the 2 TiB limit of MBR partition tables.
- Only one dskxp can run at a time.

Still: **make a backup or VM snapshot first.**

## Install

Requirements: bash 4.4+, `lvm2`, `util-linux` (sfdisk, partx, blkid, findmnt).
Optional: `whiptail` for the menus (plain text prompts are used without it),
`cryptsetup`, `mdadm`, `xfsprogs`, `btrfs-progs`, `e2fsprogs` for those features.

```
sudo make install            # installs /usr/local/sbin/dskxp
```

or just copy the single `dskxp` file:

```
sudo install -m 0755 dskxp /usr/local/sbin/dskxp
```

Debian / Ubuntu: `apt install lvm2 whiptail`
RHEL / Rocky / Alma: `dnf install lvm2 newt` (newt provides whiptail)

Tested on Debian/Ubuntu style systems; written for RHEL 8+ / Rocky / Alma as
well (util-linux 2.32+).

## Command line (scripts, Ansible)

```
dskxp --list                                       # overview + source IDs
dskxp --extend ubuntu-vg/ubuntu-lv --dry-run       # show what would happen
dskxp --extend rl/root --size 20G --yes            # grow / by 20G
dskxp --extend vg0/var --use pv:/dev/sda3 --use disk:/dev/sdb
dskxp --create data-vg/backup --use /dev/sdb --fs xfs --mount /backup --yes
dskxp --add vg0 --use free:/dev/sda:1              # only add space to the VG
dskxp --rescan                                     # only rescan the disks
```

`--use` takes an ID from `--list` (`pv:/dev/sda3`, `disk:/dev/sdb`,
`part:/dev/sdc1`, `free:/dev/sda:1`) or a plain device. Without `--use`, dskxp
grows every PV of the volume group that can grow (`auto`).

See `dskxp --help` for all options.

## Notes per platform

- **VMware / Hyper-V / Proxmox virtio-scsi:** the new size is picked up by the
  SCSI rescan that dskxp does at startup.
- **Proxmox virtio-blk (`/dev/vdX`)** and **NVMe**: the kernel normally sees the
  new size right away; NVMe namespaces are rescanned as well.
- If the new size still does not show up, a reboot of the VM always works.
- **VM snapshots**: some hypervisors cannot resize a disk that has snapshots —
  remove them first (or make one *after* resizing, before running dskxp).

## Testing

```
make lint
sudo make test     # uses loop devices, never touches real disks
```

The tests create loop devices and cover GPT, MBR (primary and logical), whole
disk PVs, new partitions, empty disks and, when device-mapper is available,
real `lvextend` + ext4/xfs/swap growth and new volumes. They run in GitHub
Actions on every push.

## License

AGPL-3.0-or-later
