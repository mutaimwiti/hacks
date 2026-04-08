#!/usr/bin/env bash
#
# fix-mongodb-selinux.sh
#
# Fixes the SELinux denial that causes MongoDB's ftdc (diagnostic data collector)
# to spam the audit log every second with:
#
#   AVC avc: denied { search } for comm="ftdc" name="nfs"
#     scontext=mongod_t tcontext=var_lib_nfs_t tclass=dir
#
# MongoDB's ftdc thread walks /proc to collect system metrics and ends up
# stat-ing /var/lib/nfs, which the default SELinux policy denies for mongod_t.
# The denial is harmless but generates thousands of audit entries per hour,
# adding I/O overhead and noise to the journal.
#
# Fix: compiles and installs a minimal SELinux policy module that allows
# mongod_t to search var_lib_nfs_t directories.
#
# Usage:
#   sudo ./fix-mongodb-selinux.sh [OPTIONS]
#
# Options:
#   --dry-run    Show what would be done without making changes
#   --remove     Remove the policy module (revert the fix)
#   --help       Show this help message

set -euo pipefail

DRY_RUN=false
REMOVE=false
MODULE_NAME="mongod_ftdc_nfs"
WORK_DIR=""

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
            --dry-run)  DRY_RUN=true; shift ;;
            --remove)   REMOVE=true; shift ;;
            --help)     usage ;;
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

check_deps() {
    local missing=()
    for cmd in checkmodule semodule_package semodule; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing required tools: ${missing[*]}"
        warn "Install with: sudo dnf install policycoreutils-devel"
        exit 1
    fi
}

remove_module() {
    if semodule -l | grep -q "^${MODULE_NAME}$"; then
        log "Removing SELinux module '${MODULE_NAME}'..."
        if $DRY_RUN; then
            dry "semodule -r ${MODULE_NAME}"
            return
        fi
        semodule -r "${MODULE_NAME}"
        log "Module removed. The ftdc audit denials will return."
    else
        log "Module '${MODULE_NAME}' is not installed. Nothing to remove."
    fi
}

install_module() {
    if semodule -l | grep -q "^${MODULE_NAME}$"; then
        log "SELinux module '${MODULE_NAME}' is already installed. Skipping."
        return
    fi

    log "Compiling and installing SELinux policy module '${MODULE_NAME}'..."

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT

    # Type enforcement: allow mongod_t to search var_lib_nfs_t dirs
    cat > "${WORK_DIR}/${MODULE_NAME}.te" <<'EOF'
module mongod_ftdc_nfs 1.0;

require {
    type mongod_t;
    type var_lib_nfs_t;
    class dir search;
}

# MongoDB ftdc walks /proc and stat-s /var/lib/nfs for system metrics.
# Allow the harmless directory search to silence audit spam.
allow mongod_t var_lib_nfs_t:dir search;
EOF

    if $DRY_RUN; then
        dry "checkmodule -M -m -o ${MODULE_NAME}.mod ${MODULE_NAME}.te"
        dry "semodule_package -o ${MODULE_NAME}.pp -m ${MODULE_NAME}.mod"
        dry "semodule -i ${MODULE_NAME}.pp"
        return
    fi

    checkmodule -M -m \
        -o "${WORK_DIR}/${MODULE_NAME}.mod" \
        "${WORK_DIR}/${MODULE_NAME}.te"

    semodule_package \
        -o "${WORK_DIR}/${MODULE_NAME}.pp" \
        -m "${WORK_DIR}/${MODULE_NAME}.mod"

    semodule -i "${WORK_DIR}/${MODULE_NAME}.pp"

    log "Module installed."
}

show_summary() {
    echo ""
    log "Summary:"
    echo "    Module name:  ${MODULE_NAME}"
    echo "    Status:       $(semodule -l | grep "^${MODULE_NAME}$" && echo 'installed' || echo 'not found')"
    echo ""
    log "Done. The ftdc audit denials should stop immediately."
    log "Verify with: ausearch -m AVC -c ftdc --raw 2>/dev/null | tail -5"
}

main() {
    parse_args "$@"
    check_root

    if $REMOVE; then
        remove_module
    else
        check_deps
        install_module
    fi

    if $DRY_RUN; then
        echo ""
        log "Dry run complete. No changes were made."
    elif ! $REMOVE; then
        show_summary
    fi
}

main "$@"
