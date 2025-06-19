#! /usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <jobfile> <disk>"
    echo "E.g.: $0 hdd.fio /dev/sdf"
    exit 1
fi

JOBFILE="$1"
TARGET="$2"

test_deps() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi

    command -v fio >/dev/null 2>&1 || {
        echo >&2 "Package 'fio' not installed. Aborting."
        exit 1
    }

    command -v jq >/dev/null 2>&1 || {
        echo >&2 "Package 'jq' not installed. Aborting."
        exit 1
    }
}

_fio() {
    local filename=$1
    local sync=${2:-0} # Default to 0 (asynchronous)
    fio --output-format=json --filename="$filename" --sync="$sync" "$JOBFILE"
}

confirm() {
    parted "$TARGET" print
    read -p $'\e[31m'"All data on $TARGET will be lost. Continue? (y/n)"$'\e[0m' -s -n 1 -r
    printf "\n\n"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Benchmark aborted."
        exit 1
    fi
}

pretty_print() {
    local result_file=$1
    local query='
    def read_bw(name): .jobs[] | select(.jobname==name+"_read").read.bw / 1024 | floor;
    def read_iops(name): .jobs[] | select(.jobname==name+"_read").read.iops | floor;

    def write_bw(name): .jobs[] | select(.jobname==name+"_write").write.bw / 1024 | floor;
    def write_iops(name): .jobs[] | select(.jobname==name+"_write").write.iops | floor;

    def bw_summary(name): read_bw(name), write_bw(name);
    def iops_summary(name): read_iops(name), write_iops(name);

    # Edit job names as needed
    bw_summary("SEQ1M_Q8T1"),
    bw_summary("SEQ1M_Q1T1"),
    iops_summary("RND4K_Q32T1"),
    iops_summary("RND4K_Q1T1")'

    mapfile -t V < <(jq "$query" "$result_file")

    echo -e "
SEQ1M_Q8T1 Read:    ${V[0]} MB/s
SEQ1M_Q8T1 Write:   ${V[1]} MB/s
SEQ1M_Q1T1 Read:    ${V[2]} MB/s
SEQ1M_Q1T1 Write:   ${V[3]} MB/s

RND4K_Q32T1 Read:   ${V[4]} IOPS
RND4K_Q32T1 Write:  ${V[5]} IOPS
RND4K_Q1T1 Read:    ${V[6]} IOPS
RND4K_Q1T1 Write:   ${V[7]} IOPS
"
}

header() {
    local msg=$1
    echo -e "\e[0;33m$msg\e[0m"
}

run_fio() {
    local filename=$1
    local sync=${2:-0} # Default to 0 (asynchronous)
    echo "Running fio with sync=$sync..."
    pretty_print <(_fio "$filename" "$sync")
}

bench_raw() {
    header "Raw disk $TARGET:"
    run_fio "$TARGET"
}

bench_btrfs() {
    local args
    [[ $1 == "cow" ]] && args="" || args=",nodatacow"
    local bench_dir=/mnt/btrfs-bench

    header "Btrfs $([[ $1 == "cow" ]] && echo cow || echo nodatacow),noatime,defaults:"
    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart btrfs 0% 100%
    mkfs.btrfs -f "$TARGET"1 >/dev/null
    mkdir -p "$bench_dir"
    mount -o "noatime$args,defaults" "$TARGET"1 "$bench_dir"
    run_fio "$bench_dir/bench.fio"
    umount "$bench_dir"
    rmdir "$bench_dir"
}

bench_zfs_zvol() {
    local volblocksize=$1
    local ashift=${2:-0} # Default to 0, which means ZFS will choose the best value
    local primarycache=${3:-metadata}
    local compression=${4:-off}

    local zpool_name="bench-zvol-$volblocksize-$ashift"
    local zvol_name="bench"

    header "ZFS zvol with volblocksize=$volblocksize, ashift=$ashift, primarycache=$primarycache, compression=$compression:"

    # Drop caches
    # echo 3 | tee /proc/sys/vm/drop_caches

    zpool create -f \
        -o ashift="$ashift" \
        -O primarycache="$primarycache" \
        -O secondarycache=none \
        -O compression="$compression" \
        -O atime=off \
        "$zpool_name" "$TARGET"

    zfs create -V 100G -b "$volblocksize" "$zpool_name/$zvol_name" 2>/dev/null

    run_fio "/dev/zvol/$zpool_name/$zvol_name" 1

    sleep 5 # Allow ZFS to flush any pending writes
    zfs destroy -f "$zpool_name/$zvol_name"
    zpool destroy "$zpool_name"
}

bench_zfs_dataset() {
    local recordsize=$1
    local ashift=${2:-0}
    local primarycache=${3:-metadata}
    local compression=${4:-off}

    local zpool_name="bench-zfs-$recordsize-$ashift"

    header "ZFS dataset with atime=off, recordsize=$recordsize, ashift=$ashift, primarycache=$primarycache, compression=$compression:"

    zpool create -f \
        -o ashift="$ashift" \
        -O primarycache="$primarycache" \
        -O secondarycache=none \
        -O compression="$compression" \
        -O atime=off \
        "$zpool_name" "$TARGET"

    zfs create -o recordsize="$recordsize" "$zpool_name/bench" 2>/dev/null

    run_fio "/$zpool_name/bench/bench.fio"

    sleep 5 # Allow ZFS to flush any pending writes
    zfs destroy -r "$zpool_name/bench"
    zpool destroy "$zpool_name"
}

test_deps
confirm

bench_raw
bench_btrfs cow
bench_btrfs nodatacow
bench_zfs_dataset 128k 0 metadata off
bench_zfs_zvol 4K 12 metadata off
bench_zfs_zvol 4K 12 none off
bench_zfs_zvol 16K 12 metadata off
