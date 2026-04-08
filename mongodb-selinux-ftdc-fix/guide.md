# MongoDB SELinux ftdc audit spam fix

MongoDB's ftdc (Full Time Diagnostic Data Capture) thread periodically walks
`/proc` to collect system metrics. In the process it stat-s `/var/lib/nfs`, which
the default Fedora SELinux policy denies for `mongod_t`. The denial is harmless —
ftdc works fine without it — but it generates an AVC audit entry every second,
adding thousands of journal entries per hour and unnecessary I/O overhead.

## Symptoms

- `journalctl` is flooded with repeated lines like:
  ```
  AVC avc: denied { search } for comm="ftdc" name="nfs" dev="nvme0n1p3"
    scontext=system_u:system_r:mongod_t:s0
    tcontext=system_u:object_r:var_lib_nfs_t:s0 tclass=dir
  ```
- `ausearch -m AVC -c ftdc` returns hundreds of entries
- System journal grows faster than expected

## Automated fix

```bash
chmod +x fix-mongodb-selinux.sh
sudo ./fix-mongodb-selinux.sh
```

Run with `--dry-run` first to preview changes:

```bash
sudo ./fix-mongodb-selinux.sh --dry-run
```

To revert:

```bash
sudo ./fix-mongodb-selinux.sh --remove
```

## Manual fix

### 1. Create the policy module source

```bash
cat > /tmp/mongod_ftdc_nfs.te <<'EOF'
module mongod_ftdc_nfs 1.0;

require {
    type mongod_t;
    type var_lib_nfs_t;
    class dir search;
}

allow mongod_t var_lib_nfs_t:dir search;
EOF
```

### 2. Compile and install

```bash
checkmodule -M -m -o /tmp/mongod_ftdc_nfs.mod /tmp/mongod_ftdc_nfs.te
semodule_package -o /tmp/mongod_ftdc_nfs.pp -m /tmp/mongod_ftdc_nfs.mod
sudo semodule -i /tmp/mongod_ftdc_nfs.pp
```

If `checkmodule` is not found:

```bash
sudo dnf install policycoreutils-devel
```

### 3. Clean up

```bash
rm /tmp/mongod_ftdc_nfs.{te,mod,pp}
```

## Why this works

SELinux enforces mandatory access control per-process. The default `mongod_t`
policy does not grant access to `var_lib_nfs_t` directories because MongoDB has
no legitimate need to read NFS state. However, the ftdc collector's `/proc` walk
causes an incidental stat on `/var/lib/nfs` as a side effect of gathering disk
metrics.

The custom policy module adds a single, tightly scoped rule: allow `mongod_t` to
**search** (not read or write) `var_lib_nfs_t` directories. This silences the
audit log without granting any meaningful additional access.

## Verifying the fix

Confirm the module is installed:

```bash
semodule -l | grep mongod_ftdc_nfs
```

Check that new AVC denials have stopped:

```bash
# Wait a minute, then check for recent ftdc denials
ausearch -m AVC -c ftdc -ts recent 2>/dev/null
```

The output should be empty or show `<no matches>`.
