#!/usr/bin/env bash
#
# fix-memory-pressure.sh
#
# Fixes for Linux systems that freeze under memory pressure, especially
# those relying solely on zram (compressed RAM) for swap with no disk-backed
# swap file. Common on Fedora and similar distributions.
#
# Fixes applied:
#   1. Creates a disk-backed swap file (default 8GB)
#   2. Sets vm.swappiness to a sensible value so the kernel pages out early
#   3. Optionally lowers JetBrains IDE max heap size
#
# Usage:
#   sudo ./fix-memory-pressure.sh [OPTIONS]
#
# Options:
#   --swap-size SIZE     Swap file size (default: 8G)
#   --swappiness VALUE   vm.swappiness value 1-100 (default: 60)
#   --ide-heap SIZE_MB   Set JetBrains IDE max heap in MB (e.g. 1536)
#   --dry-run            Show what would be done without making changes
#   --help               Show this help message

set -euo pipefail

# Defaults
SWAP_SIZE="8G"
SWAPPINESS=60
IDE_HEAP=""
DRY_RUN=false
SWAP_FILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

log() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
dry() { echo "[dry-run] $*"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --swap-size)   SWAP_SIZE="$2"; shift 2 ;;
            --swappiness)  SWAPPINESS="$2"; shift 2 ;;
            --ide-heap)    IDE_HEAP="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --help)        usage ;;
            *) warn "Unknown option: $1"; usage ;;
        esac
    done

    if [[ "$SWAPPINESS" -lt 1 || "$SWAPPINESS" -gt 100 ]]; then
        warn "Swappiness must be between 1 and 100"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        warn "This script must be run as root (sudo)."
        warn "IDE heap adjustment will be skipped if the IDE is owned by a different user."
        exit 1
    fi
}

setup_swap() {
    log "Setting up ${SWAP_SIZE} swap file at ${SWAP_FILE}..."

    if swapon --show | grep -q "$SWAP_FILE"; then
        log "Swap file ${SWAP_FILE} is already active. Skipping."
        return
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        log "Swap file exists but is not active. Activating..."
        if $DRY_RUN; then
            dry "swapon $SWAP_FILE"
            return
        fi
        chmod 600 "$SWAP_FILE"
        swapon "$SWAP_FILE"
        ensure_fstab_entry
        return
    fi

    local fs_type
    fs_type=$(df -T "$(dirname "$SWAP_FILE")" | awk 'NR==2 {print $2}')

    if $DRY_RUN; then
        if [[ "$fs_type" == "btrfs" ]]; then
            dry "btrfs filesystem mkswapfile --size ${SWAP_SIZE} ${SWAP_FILE}"
        else
            dry "fallocate -l ${SWAP_SIZE} ${SWAP_FILE}"
            dry "chmod 600 ${SWAP_FILE}"
            dry "mkswap ${SWAP_FILE}"
        fi
        dry "swapon ${SWAP_FILE}"
        dry "Add ${SWAP_FILE} to /etc/fstab"
        return
    fi

    if [[ "$fs_type" == "btrfs" ]]; then
        btrfs filesystem mkswapfile --size "${SWAP_SIZE}" "${SWAP_FILE}"
    else
        fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
    fi
    swapon "${SWAP_FILE}"
    ensure_fstab_entry

    log "Swap file created and activated."
}

ensure_fstab_entry() {
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        log "Added swap entry to /etc/fstab."
    else
        log "Swap entry already in /etc/fstab."
    fi
}

set_swappiness() {
    local current
    current=$(cat /proc/sys/vm/swappiness)

    if [[ "$current" -eq "$SWAPPINESS" ]]; then
        log "Swappiness is already set to ${SWAPPINESS}. Skipping."
        return
    fi

    log "Setting vm.swappiness from ${current} to ${SWAPPINESS}..."

    if $DRY_RUN; then
        dry "sysctl vm.swappiness=${SWAPPINESS}"
        dry "Write vm.swappiness=${SWAPPINESS} to ${SYSCTL_CONF}"
        return
    fi

    sysctl vm.swappiness="${SWAPPINESS}"
    echo "vm.swappiness=${SWAPPINESS}" > "${SYSCTL_CONF}"
    log "Swappiness set and persisted to ${SYSCTL_CONF}."
}

adjust_ide_heap() {
    if [[ -z "$IDE_HEAP" ]]; then
        return
    fi

    log "Looking for JetBrains IDE vmoptions files..."

    local found=false
    local search_dirs=(
        "/home"
        "/root"
    )

    while IFS= read -r -d '' vmoptions_file; do
        found=true
        # Match any -Xmx line
        if grep -q "^-Xmx" "$vmoptions_file"; then
            local current
            current=$(grep "^-Xmx" "$vmoptions_file" | head -1)

            if $DRY_RUN; then
                dry "In ${vmoptions_file}: change '${current}' to '-Xmx${IDE_HEAP}m'"
                continue
            fi

            sed -i "s/^-Xmx.*/-Xmx${IDE_HEAP}m/" "$vmoptions_file"
            log "Updated ${vmoptions_file}: ${current} -> -Xmx${IDE_HEAP}m"
        fi
    done < <(find "${search_dirs[@]}" -path "*/JetBrains/*/bin/*.vmoptions" -print0 2>/dev/null)

    if ! $found; then
        log "No JetBrains IDE vmoptions files found. Skipping."
    fi
}

show_summary() {
    echo ""
    log "Summary:"
    echo "    Swap file:   $(swapon --show 2>/dev/null || echo 'N/A')"
    echo "    Swappiness:  $(cat /proc/sys/vm/swappiness)"
    echo "    Total RAM:   $(free -h | awk '/^Mem:/ {print $2}')"
    echo "    Total Swap:  $(free -h | awk '/^Swap:/ {print $2}')"
    echo ""
    log "Done. If you were experiencing freezes, monitor over the next few days."
    log "Reboot to verify the swap file persists across restarts."
}

main() {
    parse_args "$@"
    check_root
    setup_swap
    set_swappiness
    adjust_ide_heap

    if $DRY_RUN; then
        echo ""
        log "Dry run complete. No changes were made."
    else
        show_summary
    fi
}

main "$@"
