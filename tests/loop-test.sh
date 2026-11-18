#!/usr/bin/env bash
# Integration tests for dskxp using loop devices.
#
#   sudo tests/loop-test.sh
#
# Needs: root, losetup with partition support, lvm2, util-linux.
# Covers the partition / PV / VG layer (works without device-mapper) and the
# plan generation for logical volumes and filesystems (unit level). On a
# machine with device-mapper, a test in a throw-away VM is still recommended
# for the LV and filesystem steps.

set -u
cd "$(dirname "$0")/.." || exit 1

DSKXP=$PWD/dskxp
WORK=$(mktemp -d /tmp/dskxp-test.XXXXXX)
export DSKXP_ALLOW_LOOP=1 DSKXP_LOG=$WORK/dskxp.log DSKXP_BACKUP_DIR=$WORK/backup DSKXP_LOCK=$WORK/lock
export LVM_SUPPRESS_FD_WARNINGS=1

PASS=0 FAIL=0
LOOPS=() MOUNTS=() VGS=()

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

cleanup() {
    local m l v
    for m in "${MOUNTS[@]}"; do umount "$m" 2>/dev/null; done
    for v in "${VGS[@]}"; do vgremove -qffy "$v" >/dev/null 2>&1; done
    for l in "${LOOPS[@]}"; do
        pvremove -qffy "$l"* >/dev/null 2>&1
        losetup -d "$l" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

mkloop() {   # mkloop NAME SIZE -> sets L to the new loop device
    truncate -s "$2" "$WORK/$1.img"
    L=$(losetup -fP --show "$WORK/$1.img") || exit 1
    LOOPS+=("$L")
}
grow_img() { truncate -s "$2" "$WORK/$1.img"; }
wait_dev() {   # make the kernel (re)read the partitions of the parent loop device, then wait
    local disk=${1%p[0-9]*} _i
    partx -a "$disk" >/dev/null 2>&1; partx -u "$disk" >/dev/null 2>&1
    for _i in $(seq 50); do [[ -b $1 ]] && return 0; sleep 0.2; done
    return 1
}
pv_bytes() { pvs --noheadings --units b --nosuffix -o pv_size "$1" 2>/dev/null | tr -d ' '; }
vg_pvs()   { vgs --noheadings -o pv_count "$1" 2>/dev/null | tr -d ' '; }
MB=1048576

[[ $EUID == 0 ]] || { echo "run as root"; exit 1; }

# ---------------------------------------------------------------------------
echo "== GPT: grow the last partition (PV) while another partition is mounted"
mkloop gpt 200M
printf 'label: gpt\nsize=50MiB, type=linux\nsize=100MiB, type=lvm\n' | sfdisk -q "$L"
wait_dev "${L}p1" && wait_dev "${L}p2"
mkfs.ext4 -q "${L}p1"; mkdir -p "$WORK/m1"; mount "${L}p1" "$WORK/m1" && MOUNTS+=("$WORK/m1")
pvcreate -q "${L}p2" && vgcreate -q dskxpt1 "${L}p2" >/dev/null && VGS+=(dskxpt1)
before=$(pv_bytes "${L}p2")
grow_img gpt 400M
out=$("$DSKXP" --list)
check "list shows grow source" grep -q "pv:${L}p2" <<<"$out"
"$DSKXP" --add dskxpt1 --dry-run >"$WORK/plan" 2>&1
check "dry-run plan relocates GPT backup header" grep -q "sfdisk --relocate gpt-bak-std $L" "$WORK/plan"
check "dry-run plan grows partition 2" grep -q "sfdisk --no-reread --no-tell-kernel -N 2 $L" "$WORK/plan"
check "dry-run changed nothing" test "$(pv_bytes "${L}p2")" = "$before"
"$DSKXP" --add dskxpt1 --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
after=$(pv_bytes "${L}p2")
check "PV grew by more than 190MiB ($before -> $after)" test $(( after - before )) -gt $(( 190 * MB ))
check "dry-run shows the preflight check with a percentage" grep -q "estimated chance of success [0-9]*%" "$WORK/plan"
check "verification after the run passed (GPT header, partition, PV)" grep -q "Result: all 3 checks passed" "$WORK/run"
check "mounted partition still mounted" findmnt -n "$WORK/m1" >/dev/null
check "partition table backup written" compgen -G "$WORK/backup/$(basename "$L")-*.sfdisk" >/dev/null
check "sfdisk sees no GPT problems" bash -c "! sfdisk -V $L 2>&1 | grep -qi 'not on the end'"
out=$("$DSKXP" --list --no-rescan)
check "nothing left to grow" bash -c "! grep -q 'pv:${L}p2' <<<\"\$1\"" _ "$out"

# ---------------------------------------------------------------------------
echo "== MBR: logical partition (PV) inside an extended partition"
mkloop mbr 200M
printf 'label: dos\nsize=50MiB, type=83\ntype=5\nsize=100MiB, type=8e\n' | sfdisk -q "$L"
if wait_dev "${L}p5"; then
    pvcreate -q "${L}p5" && vgcreate -q dskxpt2 "${L}p5" >/dev/null && VGS+=(dskxpt2)
    before=$(pv_bytes "${L}p5")
    grow_img mbr 400M
    "$DSKXP" --add dskxpt2 --dry-run >"$WORK/plan" 2>&1
    check "plan grows extended partition 2 first" grep -q "sfdisk --no-reread --no-tell-kernel -N 2 $L" "$WORK/plan"
    check "plan grows logical partition 5" grep -q "sfdisk --no-reread --no-tell-kernel -N 5 $L" "$WORK/plan"
    "$DSKXP" --add dskxpt2 --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
    after=$(pv_bytes "${L}p5")
    check "logical PV grew ($before -> $after)" test $(( after - before )) -gt $(( 200 * MB ))
else
    echo "  skip (kernel does not expose logical partitions of loop devices here)"
fi

# ---------------------------------------------------------------------------
echo "== MBR: primary partition (PV)"
mkloop mbrp 100M
printf 'label: dos\nsize=60MiB, type=8e\n' | sfdisk -q "$L"
wait_dev "${L}p1"
pvcreate -q "${L}p1" && vgcreate -q dskxpt3 "${L}p1" >/dev/null && VGS+=(dskxpt3)
before=$(pv_bytes "${L}p1")
grow_img mbrp 300M
"$DSKXP" --add dskxpt3 --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
after=$(pv_bytes "${L}p1")
check "primary PV grew ($before -> $after)" test $(( after - before )) -gt $(( 230 * MB ))

# ---------------------------------------------------------------------------
echo "== Whole-disk PV"
mkloop whole 100M
pvcreate -q "$L" && vgcreate -q dskxpt4 "$L" >/dev/null && VGS+=(dskxpt4)
before=$(pv_bytes "$L")
grow_img whole 250M
"$DSKXP" --add dskxpt4 --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
after=$(pv_bytes "$L")
check "whole-disk PV grew ($before -> $after)" test $(( after - before )) -gt $(( 140 * MB ))

# ---------------------------------------------------------------------------
echo "== Unallocated space after a non-LVM partition -> new partition + PV"
mkloop newpart 300M
printf 'label: gpt\nsize=50MiB, type=linux\n' | sfdisk -q "$L"
wait_dev "${L}p1"
mkfs.ext4 -q "${L}p1"; mkdir -p "$WORK/m5"; mount "${L}p1" "$WORK/m5" && MOUNTS+=("$WORK/m5")
out=$("$DSKXP" --list)
check "list shows free area" grep -q "free:$L:1" <<<"$out"
"$DSKXP" --add dskxpt5 --use "free:$L:1" --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
check "new partition 2 created" test -b "${L}p2"
check "new VG dskxpt5 created on ${L}p2" test "$(pvs --noheadings -o vg_name "${L}p2" 2>/dev/null | tr -d ' ')" = dskxpt5
VGS+=(dskxpt5)
check "new PV is larger than 200MiB" test "$(pv_bytes "${L}p2")" -gt $(( 200 * MB ))

# ---------------------------------------------------------------------------
echo "== Empty disk -> PV added to an existing VG"
mkloop empty 200M
out=$("$DSKXP" --list --no-rescan)
check "list shows empty disk" grep -q "disk:$L" <<<"$out"
"$DSKXP" --add dskxpt4 --use "$L" --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
check "dskxpt4 now has 2 PVs" test "$(vg_pvs dskxpt4)" = 2

# ---------------------------------------------------------------------------
echo "== Startup overview"
"$DSKXP" --list --no-rescan >"$WORK/out" 2>"$WORK/err"
check "startup steps are shown on stderr" grep -q '^\[6/6\] Looking for free space' "$WORK/err"
check "startup shows the result of each step" grep -q '^\[4/6\] Reading LVM .* VG, .* PV, .* LV' "$WORK/err"
check "stdout of --list stays clean" bash -c "! grep -q '^\[[0-9]/6\]' '$WORK/out' && grep -q '^DISKS' '$WORK/out'"
"$DSKXP" --list --no-rescan -q >"$WORK/out" 2>"$WORK/err"
check "-q hides the startup overview" test ! -s "$WORK/err"
"$DSKXP" --list -v >/dev/null 2>"$WORK/err"
check "-v shows the commands that are run" grep -q '\$ sfdisk -d /dev/' "$WORK/err"
check "-v shows the LVM queries" grep -q '\$ pvs -o' "$WORK/err"
check "startup is written to the log" grep -q 'step 6/6: Looking for free space' "$DSKXP_LOG"

# ---------------------------------------------------------------------------
echo "== Safety"
mkloop used 100M
mkfs.ext4 -q "$L"
out=$("$DSKXP" --list --no-rescan)
check "disk with a filesystem is not offered" bash -c "! grep -q 'disk:$L' <<<\"\$1\"" _ "$out"
check "unknown source is rejected" bash -c "! '$DSKXP' --add dskxpt4 --use /dev/nonexistent --dry-run >/dev/null 2>&1"
check "too large size is rejected" bash -c "! '$DSKXP' --create dskxpt4/big --size 99T --dry-run >/dev/null 2>&1"

# ---------------------------------------------------------------------------
echo "== Logical volumes and filesystems (needs device-mapper)"
fs_bytes() { df -B1 --output=size "$1" | tail -n1 | tr -d ' '; }
if ! dmsetup version >/dev/null 2>&1; then
    echo "  skip (no device-mapper in this kernel/container)"
else
    # ext4, mounted, on a partition that has to grow first
    mkloop lv 200M
    printf 'label: gpt\nsize=150MiB, type=lvm\n' | sfdisk -q "$L"
    wait_dev "${L}p1"
    pvcreate -q "${L}p1" && vgcreate -q dskxpt6 "${L}p1" >/dev/null && VGS+=(dskxpt6)
    lvcreate -q -y -L 100M -n data dskxpt6 >/dev/null
    mkfs.ext4 -q /dev/dskxpt6/data
    mkdir -p "$WORK/data"; mount /dev/dskxpt6/data "$WORK/data" && MOUNTS=("$WORK/data" "${MOUNTS[@]}")
    before=$(fs_bytes "$WORK/data")
    grow_img lv 500M
    "$DSKXP" --extend dskxpt6/data --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
    after=$(fs_bytes "$WORK/data")
    check "mounted ext4 grew with the disk ($before -> $after)" test $(( after - before )) -gt $(( 300 * MB ))

    # xfs, mounted, fixed size (first give the VG more room)
    grow_img lv 1200M
    "$DSKXP" --add dskxpt6 --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
    check "--add grew the VG" test "$(vgs --noheadings --units b --nosuffix -o vg_free dskxpt6 | tr -d ' ')" -gt $(( 600 * MB ))
    if command -v mkfs.xfs >/dev/null && lvcreate -q -y -L 320M -n xfs2 dskxpt6 >/dev/null; then
        mkfs.xfs -q /dev/dskxpt6/xfs2
        mkdir -p "$WORK/xfs"; mount /dev/dskxpt6/xfs2 "$WORK/xfs" && MOUNTS=("$WORK/xfs" "${MOUNTS[@]}")
        before=$(fs_bytes "$WORK/xfs")
        "$DSKXP" --extend dskxpt6/xfs2 --size 100M --yes >"$WORK/run" 2>&1 || cat "$WORK/run"
        after=$(fs_bytes "$WORK/xfs")
        check "mounted xfs grew by ~100M ($before -> $after)" test $(( after - before )) -gt $(( 90 * MB ))
    else
        echo "  skip xfs (mkfs.xfs missing)"
    fi

    # swap (not active): UUID must survive
    lvcreate -q -y -L 32M -n swap dskxpt6 >/dev/null
    mkswap -q /dev/dskxpt6/swap >/dev/null 2>&1 || mkswap /dev/dskxpt6/swap >/dev/null
    uuid=$(blkid -o value -s UUID /dev/dskxpt6/swap)
    "$DSKXP" --extend dskxpt6/swap --size 32M --yes --no-rescan >"$WORK/run" 2>&1 || cat "$WORK/run"
    check "swap LV grew to 64M" test "$(lvs --noheadings --units b --nosuffix -o lv_size dskxpt6/swap | tr -d ' ')" = $(( 64 * MB ))
    check "swap kept its UUID" test "$(blkid -o value -s UUID /dev/dskxpt6/swap)" = "$uuid"

    # new LV with filesystem, mounted, without touching /etc/fstab
    "$DSKXP" --create dskxpt6/new --size 64M --fs ext4 --mount "$WORK/new" --no-fstab --yes --no-rescan >"$WORK/run" 2>&1 || cat "$WORK/run"
    findmnt -n "$WORK/new" >/dev/null && MOUNTS=("$WORK/new" "${MOUNTS[@]}")
    check "new LV created and mounted" test "$(findmnt -n -o SOURCE "$WORK/new" 2>/dev/null)" = /dev/mapper/dskxpt6-new
    check "mount point in use is rejected" bash -c "! '$DSKXP' --create dskxpt6/x --size 8M --mount '$WORK/new' --dry-run --no-rescan >/dev/null 2>&1"
    check "new LV run verified (size, filesystem, mount)" grep -q "Result: all 3 checks passed" "$WORK/run"

    # --check lists the volumes with a percentage
    out=$("$DSKXP" --check --no-rescan 2>&1)
    check "--check lists dskxpt6/data with a chance" grep -qE "dskxpt6/data .*[0-9]+%" <<<"$out"

    # read-only mounted filesystem: preflight must block, nothing may change
    lvcreate -q -y -L 32M -n ro dskxpt6 >/dev/null
    mkfs.ext4 -q /dev/dskxpt6/ro
    mkdir -p "$WORK/ro"; mount -o ro /dev/dskxpt6/ro "$WORK/ro" && MOUNTS=("$WORK/ro" "${MOUNTS[@]}")
    if "$DSKXP" --extend dskxpt6/ro --size 8M --yes --no-rescan >"$WORK/run" 2>&1; then rc=0; else rc=1; fi
    check "read-only mount: run refused" test "$rc" = 1
    check "read-only mount: preflight says BLOCKED" grep -q "BLOCKED" "$WORK/run"
    check "read-only mount: LV size unchanged" test "$(lvs --noheadings --units b --nosuffix -o lv_size dskxpt6/ro | tr -d ' ')" = $(( 32 * MB ))
fi

# ---------------------------------------------------------------------------
echo "== Plan generation for logical volumes (unit tests)"
plan_case() {   # plan_case NAME EXPECTED_REGEX -- bash code
    local name=$1 expect=$2; shift 3
    local out
    out=$(bash -c "source '$DSKXP'; TS=test; $*; plan_text" 2>&1)
    if grep -qE -- "$expect" <<<"$out"; then ok "$name"; else bad "$name"; printf '%s\n' "$out" | sed 's/^/       /'; fi
}
# shellcheck disable=SC2016  # expanded later, inside the sourced script
setup='VG_EXT[vg]=4194304; VG_FREE[vg]=10737418240; for k in vg/root vg/var vg/data vg/home vg/swap pve/data; do LV_SIZE[$k]=1073741824; done; plan_reset'
plan_case "ext4 mounted: lvextend + resize2fs" 'lvextend -L \+5120m vg/root.*resize2fs /dev/vg/root' -- \
    "$setup; LV_ATTR[vg/root]=-wi-ao----; LV_FS[vg/root]=ext4; LV_MNT[vg/root]=/; LV_FSDEV[vg/root]=/dev/vg/root; LV_CRYPT[vg/root]=; plan_extend_lv vg/root 5368709120; plan_text | tr '\n' ' '; exit"
plan_case "xfs mounted: xfs_growfs on mount point" 'lvextend -l \+100%FREE vg/var.*xfs_growfs /var' -- \
    "$setup; LV_ATTR[vg/var]=-wi-ao----; LV_FS[vg/var]=xfs; LV_MNT[vg/var]=/var; LV_FSDEV[vg/var]=/dev/vg/var; LV_CRYPT[vg/var]=; plan_extend_lv vg/var all; plan_text | tr '\n' ' '; exit"
plan_case "ext4 unmounted: e2fsck before resize2fs" 'e2fsck -f -p /dev/vg/data.*resize2fs' -- \
    "$setup; LV_ATTR[vg/data]=-wi-a-----; LV_FS[vg/data]=ext4; LV_MNT[vg/data]=; LV_FSDEV[vg/data]=/dev/vg/data; LV_CRYPT[vg/data]=; plan_extend_lv vg/data all; plan_text | tr '\n' ' '; exit"
plan_case "LUKS on LV: cryptsetup resize before the filesystem" 'lvextend.*cryptsetup resize home_crypt.*resize2fs /dev/mapper/home_crypt' -- \
    "$setup; LV_ATTR[vg/home]=-wi-ao----; LV_FS[vg/home]=ext4; LV_MNT[vg/home]=/home; LV_FSDEV[vg/home]=/dev/mapper/home_crypt; LV_CRYPT[vg/home]=home_crypt; plan_extend_lv vg/home all; plan_text | tr '\n' ' '; exit"
plan_case "active swap: swapoff, lvextend, mkswap, swapon" 'swapoff.*lvextend.*mkswap.*swapon' -- \
    "$setup; blkid() { echo 1111-2222; }; LV_ATTR[vg/swap]=-wi-ao----; LV_FS[vg/swap]=swap; LV_MNT[vg/swap]='[SWAP]'; LV_FSDEV[vg/swap]=/dev/vg/swap; LV_CRYPT[vg/swap]=; plan_extend_lv vg/swap all; plan_text | tr '\n' ' '; exit"
plan_case "thin pool: no filesystem step" 'lvextend -l \+100%FREE pve/data.*thin pool' -- \
    "$setup; LV_ATTR[pve/data]=twi-aotz--; LV_FS[pve/data]='(thin pool)'; LV_MNT[pve/data]=; LV_FSDEV[pve/data]=; LV_CRYPT[pve/data]=; plan_extend_lv pve/data all; plan_text | tr '\n' ' '; exit"
plan_case "create xfs LV with fstab entry" "lvcreate -y -L 2048m -n backup vg.*mkfs.xfs /dev/vg/backup.*mkdir -p /backup.*fstab.*xfs defaults 0 0.*mount /backup" -- \
    "$setup; plan_create_lv vg backup 2147483648 xfs /backup 1; plan_text | tr '\n' ' '; exit"
plan_case "size is rounded down to whole extents" 'lvextend -L \+1024m vg/root' -- \
    "$setup; LV_ATTR[vg/root]=-wi-ao----; LV_FS[vg/root]=ext4; LV_MNT[vg/root]=/; LV_FSDEV[vg/root]=/dev/vg/root; LV_CRYPT[vg/root]=; plan_extend_lv vg/root 1075838976; plan_text | tr '\n' ' '; exit"

echo "== Preflight scoring and verification (unit tests)"
pf() { bash -c "source '$DSKXP'; plan_reset; $1; preflight; echo \"fails=\$PF_FAILS score=\$(pf_result)\"" 2>/dev/null | tail -n1; }
out=$(pf "have() { [[ \$1 != xfs_growfs ]]; }; add_step x 'xfs_growfs /srv'")
check "missing tool blocks the run (score 0)" test "$out" = "fails=1 score=0"
out=$(pf "pf_distro() { pf_ok distro; }; add_step x 'cryptsetup resize foo'")
check "LUKS step costs 10% (score 90)" test "$out" = "fails=0 score=90"
out=$(pf "pf_distro() { pf_ok distro; }; add_step x 'mdadm --grow /dev/md0 --size=max'; add_step y 'cryptsetup resize foo'")
check "warnings add up (mdadm + LUKS: score 75)" test "$out" = "fails=0 score=75"
out=$(pf "pf_distro() { pf_ok distro; }; PLAN_AMOUNT=1000; PLAN_AVAIL=1010; PLAN_NSRC=1; add_step x 'lvextend -L +1m vg/lv'")
check "size close to the estimate costs 10%" test "$out" = "fails=0 score=90"
check "verification detects a wrong size" bash -c "source '$DSKXP'; PLAN_VERIFY=(); add_verify part sda 999999999999999 '' 'x'; ! verify_plan"
check "verification detects a missing LV" bash -c "source '$DSKXP'; PLAN_VERIFY=(); add_verify exists nosuchvg/nosuchlv '' '' 'x'; ! verify_plan"

echo "== Missing tools (unit tests with a fake package manager)"
hint() { DSKXP_OS_FAMILY=$1 bash -c "source '$DSKXP'; have() { false; }; install_hint ${*:2}" 2>/dev/null; }
check "debian: xfs_growfs -> apt-get install xfsprogs" grep -q '^apt-get install -y xfsprogs ' <<<"$(hint debian xfs_growfs)"
check "debian: sfdisk -> fdisk, whiptail -> whiptail" grep -q 'install -y fdisk whiptail ' <<<"$(hint debian sfdisk whiptail)"
check "rhel: whiptail -> dnf install newt" test "$(hint rhel whiptail)" = "dnf install -y newt"
check "suse: lvm tools -> one lvm2 package" test "$(hint suse pvs lvextend)" = "zypper --non-interactive install lvm2"
check "unknown distribution: no hint" bash -c "! DSKXP_OS_FAMILY=unknown bash -c \"source '$DSKXP'; install_hint mdadm\" >/dev/null 2>&1"
check "preflight names the package to install" bash -c "source '$DSKXP'; export DSKXP_OS_FAMILY=debian; have() { [[ \$1 != mdadm ]]; }; plan_reset; add_step x 'mdadm --grow /dev/md0 --size=max'; preflight; preflight_text | grep -q 'install with: apt-get install -y mdadm'"

FAKE=$WORK/fakebin; mkdir -p "$FAKE"
cat >"$FAKE/apt-get" <<EOF
#!/bin/sh
echo "\$*" >>"$FAKE/apt-get.calls"
printf '#!/bin/sh\nexit 0\n' >"$FAKE/xfs_growfs"; chmod +x "$FAKE/xfs_growfs"
EOF
chmod +x "$FAKE/apt-get"
offer() {   # offer OPTS -> runs offer_install for xfs_growfs with the fake apt-get
    rm -f "$FAKE/xfs_growfs" "$FAKE/apt-get.calls"
    PATH="$FAKE:$PATH" DSKXP_OS_FAMILY=debian bash -c "source '$DSKXP'; have() { [[ \$1 == xfs_growfs ]] && { [[ -x '$FAKE/xfs_growfs' ]]; return; }; command -v \"\$1\" >/dev/null; }; $1; offer_install test xfs_growfs" </dev/null >/dev/null 2>&1
}
offer "OPT_YES=1"
check "--yes alone never installs" test ! -e "$FAKE/apt-get.calls"
offer "OPT_DRY_RUN=1; OPT_INSTALL=1"
check "--dry-run never installs" test ! -e "$FAKE/apt-get.calls"
offer "OPT_INSTALL=1; OPT_YES=1"
check "--install-missing installs the right package" grep -q '^install -y xfsprogs' "$FAKE/apt-get.calls"
check "--install-missing: tool available afterwards" test -x "$FAKE/xfs_growfs"

echo "== Size parsing"
psize() { bash -c "source '$DSKXP'; parse_size '$1' 1073741824"; }
check "10G"  test "$(psize 10G)" = 10737418240
check "+512M" test "$(psize +512M)" = 536870912
check "1.5T" test "$(psize 1.5T)" = 1649267441664
check "50%"  test "$(psize 50%)" = 536870912
check "all"  test "$(psize all)" = all
check "10GiB" test "$(psize 10GiB)" = 10737418240
check "garbage rejected" bash -c "source '$DSKXP'; ! parse_size abc 1"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
