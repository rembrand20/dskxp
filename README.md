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
5. dskxp shows **every command it will run** plus a **preflight check** with an
   estimated chance of success. Nothing changes until you confirm.
6. Afterwards it **verifies** every change and reports `OK` / `FAIL` per item.

## What you see when it starts

dskxp first shows what it is doing, step by step (on stderr, so the output of
`--list` and `--check` stays clean for scripts):

```
dskxp 0.2.0 - starting
[1/6] Checking required tools .............. ok (util-linux, lvm2, whiptail)
[2/6] Rescanning disks
      SCSI hosts scanned for new disks: host0 host1 host2
      disks asked for their current size: sda sdb
      /dev/sda: GREW 20.0G -> 60.0G
      => changes found
[3/6] Reading partition tables
      /dev/sda            60.0G  gpt, 3 partition(s)
      => 1 disk(s)
[4/6] Reading LVM .......................... 1 VG, 1 PV, 2 LV
[5/6] Checking filesystems and mounts
      rl/root                     17.0G  xfs on / (92% used)
      rl/swap                      2.0G  swap on [SWAP]
      => 1 filesystem(s)
[6/6] Looking for free space
         ~40.0G  grow /dev/sda3 (volume group rl)
      => 1 source(s), ~40.0G
Done in 1.2s
Press Enter to open the menu...
```

- `-v` / `--verbose` also shows every read-only command it runs
  (`sfdisk -d`, `pvs`, `blkid`, the rescan writes in `/sys`, ...).
- `-q` / `--quiet` hides the overview.
- Every step is also written to `/var/log/dskxp.log`.
- While a plan runs you see every step with its exact command and output.

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

## Preflight check, verification and `--check`

**Before** running a plan, dskxp checks:

| Check | Result if it fails |
|---|---|
| every tool the plan needs is installed (`xfs_growfs`, `cryptsetup`, ...) | FAIL |
| `sfdisk` supports online partition resizing (util-linux 2.29+) | FAIL |
| the volume group is complete (no missing PV) and `vgck` is happy | FAIL |
| partition tables are valid (`sfdisk -V`) | FAIL |
| the target filesystem is not mounted read-only | FAIL |
| enough free RAM to turn swap off temporarily | FAIL |
| kernel and on-disk partition table agree (else: reboot first) | WARN −15% |
| ext filesystem has no recorded errors / is clean | WARN −25% / −15% |
| requested size is not within 3% of the estimated maximum | WARN −10% |
| scenario not covered by the automated tests (LUKS −10%, mdraid −15%, btrfs −10%) | WARN |
| `/etc/fstab` has no existing problems (when it will be edited) | WARN −10% |
| distribution family tested (RHEL family −5%, others −10%) | WARN |

The **chance of success** is 100% minus the penalty of each warning. It is an
honest estimate, not a mathematical probability. A FAIL blocks the run
(`--force` overrides it, not recommended).

**After** the run, every change is verified: partition sizes, the GPT backup
header position, PV size, PV membership of the VG, LV size, filesystem size
(`df`, it must grow along with the volume), swap UUID and state, the new
filesystem type, the mount and the `/etc/fstab` entry. dskxp exits with
status 1 if any check fails, so scripts and Ansible notice it.

**`dskxp --check`** is a health report for the whole server: for every logical
volume it shows how much space can be added and the estimated chance of
success — without changing anything. `--dry-run` instead shows the full plan
and preflight for one specific action.

```
PREFLIGHT CHECK FOR EVERY LOGICAL VOLUME
  LV                                EXTRA   CHANCE  REMARKS
  ubuntu-vg/ubuntu-lv              ~40.0G     100%  all checks OK
  ubuntu-vg/swap                   ~40.0G      85%  the kernel still uses an older partition table ...
```

## Missing tools

dskxp knows which package provides every tool it uses, for Debian/Ubuntu
(`apt-get`), RHEL/Rocky/Alma/Fedora (`dnf`/`yum`), SUSE (`zypper`), Arch
(`pacman`) and Alpine (`apk`).

| Situation | What happens |
|---|---|
| a basic tool (`sfdisk`, LVM, ...) is missing at startup | menu: asks to install it; command line: stops with the exact install command |
| a tool needed for this plan is missing (`xfs_growfs`, `cryptsetup`, `mdadm`, ...) | preflight FAIL with the install command; the menu offers to install it and re-runs the preflight |
| `whiptail` is missing | offers to install it; plain text menus work without it |
| `--install-missing` | installs without asking (for scripts) |
| `--yes` or `--dry-run` without `--install-missing` | never installs anything |

```
[FAIL] missing tools needed by this plan: xfs_growfs - install with: apt-get install -y xfsprogs || { apt-get update && apt-get install -y xfsprogs; }
```

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
dskxp --check                                      # chance of success per volume
dskxp --extend ubuntu-vg/ubuntu-lv --dry-run       # show what would happen
dskxp --extend rl/root --size 20G --yes            # grow / by 20G
dskxp --extend vg0/var --use pv:/dev/sda3 --use disk:/dev/sdb
dskxp --create data-vg/backup --use /dev/sdb --fs xfs --mount /backup --yes
dskxp --add vg0 --use free:/dev/sda:1              # only add space to the VG
dskxp --rescan                                     # only rescan the disks
dskxp --extend vg0/data --yes --install-missing    # install missing tools first
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
