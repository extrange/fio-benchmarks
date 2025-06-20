#! /usr/bin/env bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Tests sequential read performance degradation on COW filesystems after randomly writing to a file."
    echo "Usage: $0 <disk>"
    echo "E.g.: $0 /dev/sdf"
    exit 1
fi

TARGET="$1"
JOBFILE="inplace.conf"

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
    def read_bw(name): .jobs[] | select(.jobname==name).read.bw / 1024 | floor;
    def write_bw(name): .jobs[] | select(.jobname==name).write.bw / 1024 | floor;
    def write_iops(name): .jobs[] | select(.jobname==name).write.iops | floor;

    # Edit job names as needed
    write_bw("seq_write"),
    read_bw("seq_read"),
    write_iops("rand_write"),
    read_bw("seq_read_after")'

    mapfile -t V < <(jq "$query" "$result_file")

    echo -e "
SEQ1M_Q8T1 Write:       ${V[0]} MB/s
SEQ1M_Q8T1 Read (Pre):  ${V[1]} MB/s
RND4K_Q32T1 Write:      ${V[2]} IOPS
SEQ1M_Q8T1 Read (Post): ${V[3]} MB/s
"
}

header() {
    local msg=$1
    echo -e "\e[0;33m$msg\e[0m"
}

run_fio() {
    pretty_print <(fio --output-format=json --filename="$1" "$JOBFILE")
}

bench_btrfs() {
    local args="$1,noatime,defaults"
    local bench_dir=/mnt/btrfs-bench

    header "Btrfs $args:"
    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart btrfs 0% 100%
    mkfs.btrfs -f "$TARGET"1 >/dev/null
    mkdir -p "$bench_dir"
    mount -o "$args" "$TARGET"1 "$bench_dir"
    run_fio "$bench_dir/bench.fio"
    umount "$bench_dir"
    rmdir "$bench_dir"
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

bench_zfs_dataset_snapshots() {
    local recordsize=$1
    local ashift=${2:-0}
    local primarycache=${3:-metadata}
    local compression=${4:-off}

    local zpool_name="bench-zfs-$recordsize-$ashift"

    header "ZFS dataset w/snapshots with atime=off, recordsize=$recordsize, ashift=$ashift, primarycache=$primarycache, compression=$compression:"

    zpool create -f \
        -o ashift="$ashift" \
        -O primarycache="$primarycache" \
        -O secondarycache=none \
        -O compression="$compression" \
        -O atime=off \
        "$zpool_name" "$TARGET"

    zfs create -o recordsize="$recordsize" "$zpool_name/bench" 2>/dev/null

    local filename="/$zpool_name/bench/bench.fio"

    echo -e "
SEQ1M_Q8T1 Write: $(fio --output-format=json --section=seq_write --filename="$filename" "$JOBFILE" | jq -r '.jobs[] | select(.jobname == "seq_write").write.bw / 1024 | floor') MB/s"

    local snapshot_name

    (
        while true; do
            snapshot_name=$(date +%s%3N)
            zfs snapshot "$zpool_name/bench@$snapshot_name"
            sleep 0.2
        done
    ) &

    local bg_pid=$!

    echo -e "RND4K_Q32T1 Write: $(fio --output-format=json --section=rand_write --filename="$filename" "$JOBFILE" | jq -r '.jobs[] | select(.jobname == "rand_write").write.iops | floor') IOPS"

    kill $bg_pid

    echo "Created $(zfs list -t snapshot -H -o name -r "$zpool_name/bench" | wc -l) snapshots"

    echo -e "SEQ1M_Q8T1 Read: $(fio --output-format=json --section=seq_read_after --filename="$filename" "$JOBFILE" | jq -r '.jobs[] | select(.jobname == "seq_read_after").read.bw / 1024 | floor') MB/s"

    sleep 5 # Allow ZFS to flush any pending writes
    zfs destroy -r "$zpool_name/bench"
    zpool destroy "$zpool_name"
}

test_deps
confirm

bench_btrfs datacow
bench_btrfs nodatacow
bench_btrfs nodatacow,autodefrag
bench_btrfs datacow,autodefrag
bench_zfs_dataset 128k 0 metadata off
bench_zfs_dataset_snapshots 128k 0 metadata off
