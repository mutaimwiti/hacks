#!/usr/bin/env bash
#
# fix-i915-suspend.sh
#
# Fixes Intel i915 GPU lockups after suspend/resume on Meteor Lake (Arrow Lake)
# systems. The lockup freezes the compositor (gnome-shell), which cascades into
# a full system freeze requiring a hard reboot.
#
# Root cause: Panel Self Refresh (PSR) and aggressive display power states
# interact badly with suspend/resume on newer Intel GPUs, causing GuC
# communication failures and compositor stalls.
#
# Fixes applied:
#   1. Disables PSR via i915 module parameter (primary fix)
#   2. Optionally disables display power-saving states (DC) for stubborn cases
#   3. Persists settings via modprobe.d and rebuilds initramfs
#
# Usage:
#   sudo ./fix-i915-suspend.sh [OPTIONS]
#
# Options:
#   --disable-dc    Also disable display C-states (use if PSR-only fix is not enough)
#   --dry-run       Show what would be done without making changes
#   --help          Show this help message

set -euo pipefail

DISABLE_DC=false
DRY_RUN=false
MODPROBE_CONF="/etc/modprobe.d/i915-suspend-fix.conf"

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
            --disable-dc)  DISABLE_DC=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --help)        usage ;;
            *) warn "Unknown option: $1"; usage ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        warn "This script must be run as root (sudo)."
        exit 1
    fi
}

check_i915() {
    if ! lsmod | grep -q "^i915"; then
        warn "i915 module is not loaded. This fix is for Intel integrated GPUs only."
        exit 1
    fi

    local gpu_info
    gpu_info=$(lspci | grep -i "VGA.*Intel" || true)
    if [[ -z "$gpu_info" ]]; then
        warn "No Intel VGA device found."
        exit 1
    fi
    log "Detected GPU: ${gpu_info}"
}

write_modprobe_conf() {
    local options="options i915 enable_psr=0"
    if $DISABLE_DC; then
        options="options i915 enable_psr=0 enable_dc=0"
    fi

    if [[ -f "$MODPROBE_CONF" ]]; then
        local current
        current=$(cat "$MODPROBE_CONF")
        if [[ "$current" == "$options" ]]; then
            log "Modprobe config already has the correct settings. Skipping."
            return
        fi
        log "Updating existing modprobe config at ${MODPROBE_CONF}..."
    else
        log "Creating modprobe config at ${MODPROBE_CONF}..."
    fi

    if $DRY_RUN; then
        dry "Write '${options}' to ${MODPROBE_CONF}"
        return
    fi

    echo "$options" > "$MODPROBE_CONF"
    log "Written: ${options}"
}

rebuild_initramfs() {
    log "Rebuilding initramfs so the setting applies at early boot..."

    if $DRY_RUN; then
        if command -v dracut &>/dev/null; then
            dry "dracut --force"
        elif command -v update-initramfs &>/dev/null; then
            dry "update-initramfs -u"
        else
            dry "mkinitcpio -P"
        fi
        return
    fi

    if command -v dracut &>/dev/null; then
        dracut --force
    elif command -v update-initramfs &>/dev/null; then
        update-initramfs -u
    elif command -v mkinitcpio &>/dev/null; then
        mkinitcpio -P
    else
        warn "No known initramfs tool found. You may need to rebuild manually."
        return
    fi
    log "Initramfs rebuilt."
}

apply_runtime() {
    log "Applying settings to running kernel (takes effect without reboot for new suspend cycles)..."

    if $DRY_RUN; then
        dry "echo 0 > /sys/module/i915/parameters/enable_psr"
        if $DISABLE_DC; then
            dry "echo 0 > /sys/module/i915/parameters/enable_dc"
        fi
        return
    fi

    # Runtime writes may fail on some kernels — not critical since reboot will apply
    if echo 0 > /sys/module/i915/parameters/enable_psr 2>/dev/null; then
        log "PSR disabled at runtime."
    else
        warn "Could not write PSR parameter at runtime (read-only on this kernel)."
        warn "A reboot is required for the fix to take effect."
    fi

    if $DISABLE_DC; then
        if echo 0 > /sys/module/i915/parameters/enable_dc 2>/dev/null; then
            log "DC states disabled at runtime."
        else
            warn "Could not write DC parameter at runtime. Reboot required."
        fi
    fi
}

show_summary() {
    echo ""
    log "Summary:"
    echo "    Config file: ${MODPROBE_CONF}"
    echo "    PSR:         disabled"
    if $DISABLE_DC; then
        echo "    DC states:   disabled"
    else
        echo "    DC states:   unchanged (default)"
    fi
    echo ""
    log "Done. Reboot to fully apply. Monitor with:"
    log "    journalctl -b -k | grep -i 'i915.*error\\|drm.*error'"
    log "If freezes persist after reboot, re-run with --disable-dc."
}

main() {
    parse_args "$@"
    check_root
    check_i915
    write_modprobe_conf
    rebuild_initramfs
    apply_runtime

    if $DRY_RUN; then
        echo ""
        log "Dry run complete. No changes were made."
    else
        show_summary
    fi
}

main "$@"
