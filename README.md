# hacks

Workarounds and fixes for common dev environment issues.

Each folder is a self-contained fix with an install script and a step-by-step guide.

## Index

| Fix | Description |
|-----|-------------|
| [mongodb-fedora-shstk-fix](mongodb-fedora-shstk-fix/) | MongoDB SIGSEGV crash on Fedora 43+ (kernel 6.19+) due to Shadow Stack |
| [linux-memory-pressure-fix](linux-memory-pressure-fix/) | System freezes under memory pressure on zram-only systems |
| [i915-suspend-freeze-fix](i915-suspend-freeze-fix/) | Intel i915 GPU lockup after suspend/resume on Meteor Lake / Arrow Lake |
| [earlyoom-oom-fix](earlyoom-oom-fix/) | Prevent system freezes from OOM by killing runaway processes early |
| [mongodb-selinux-ftdc-fix](mongodb-selinux-ftdc-fix/) | MongoDB ftdc SELinux audit spam (AVC denied search var_lib_nfs_t) |
