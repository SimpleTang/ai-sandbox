#!/bin/bash
# Release cached inodes of the persistent machine's virtiofs mounts (the host Home)
# before they pile up. Runs as root under aibox-dev-cache-trim.service.
#
# virtiofs keeps one open file handle in the Mac's VM process for every inode the
# guest has cached, and the guest only evicts cached inodes under memory pressure.
# A walk over a large part of the Home (find, an indexer, a tool's startup scan) caches
# over ten thousand inodes per second; left alone it exhausts the Mac's system-wide
# file table (kern.maxfiles, 491520) within a minute and macOS starts killing system
# processes. Checking every two seconds bounds the peak at about the threshold plus
# what such a walk caches between two checks. The fuse_inode slab count matches the
# host handle count closely, and one check costs a few milliseconds. The drop is global
# and makes the next access to evicted files a little slower, so do it only past the
# threshold.
set -euo pipefail

threshold=50000
interval=2
# Overridable only so tests can run this against fixture files.
slabinfo="${AIBOX_SLABINFO:-/proc/slabinfo}"
drop_caches="${AIBOX_DROP_CACHES:-/proc/sys/vm/drop_caches}"

fuse_inodes() {
    local name active rest
    while read -r name active rest; do
        if [[ "$name" == fuse_inode ]]; then
            printf '%s\n' "$active"
            return
        fi
    done < "$slabinfo"
    printf '0\n'
}

trim() {
    local before
    before="$(fuse_inodes)"
    if (( before <= threshold )); then
        return
    fi
    # A single pass frees leaf entries first; directories still pinned by their
    # children go in the second pass.
    printf '2\n' > "$drop_caches"
    printf '2\n' > "$drop_caches"
    echo "virtiofs cached inodes: $before -> $(fuse_inodes) (threshold $threshold)"
}

if [[ "${1:-}" == "--once" ]]; then
    trim
    exit 0
fi
while true; do
    trim
    sleep "$interval"
done
