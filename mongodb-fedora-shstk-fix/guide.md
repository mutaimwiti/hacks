# MongoDB on Fedora 43+ (kernel 6.19+) — SHSTK crash fix

MongoDB crashes with `SIGSEGV` (signal 11, exit code 139) on Fedora 43+ due to an
incompatibility between MongoDB's coroutine implementation and the hardware Shadow Stack
(SHSTK) feature enabled in kernel 6.19+. This affects MongoDB 7.0, 8.0, and 8.2.

## Symptoms

- `mongod` starts and then crashes ~30 seconds later
- `systemctl status mongod` shows `code=dumped, signal=SEGV`
- `journalctl -u mongod` shows a core dump

## Automated install

```bash
chmod +x install.sh
./install.sh
```

The script removes any existing MongoDB installation, installs 8.0 from the official
repo, applies the workaround, and enables auto-start.

## Manual install

### 1. Remove existing MongoDB (if installed)

```bash
sudo systemctl stop mongod
sudo systemctl disable mongod
sudo dnf remove -y mongodb-org mongodb-org-server mongodb-org-mongos \
  mongodb-org-database mongodb-org-tools mongodb-org-database-tools-extra \
  mongodb-mongosh mongodb-database-tools
sudo rm -rf /var/lib/mongo /var/log/mongodb /tmp/mongodb-27017.sock
sudo rm -f /etc/yum.repos.d/mongodb-org-*.repo /etc/mongod.conf
sudo rm -rf /etc/systemd/system/mongod.service.d
```

### 2. Add the MongoDB 8.0 repo

```bash
sudo tee /etc/yum.repos.d/mongodb-org-8.0.repo > /dev/null <<'EOF'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF
```

### 3. Install MongoDB

```bash
sudo dnf install -y mongodb-org
```

### 4. Apply the Shadow Stack workaround

Create a systemd drop-in that disables SHSTK for the `mongod` process:

```bash
sudo mkdir -p /etc/systemd/system/mongod.service.d
sudo tee /etc/systemd/system/mongod.service.d/shstk-fix.conf > /dev/null <<'EOF'
[Service]
Environment="GLIBC_TUNABLES=glibc.cpu.hwcaps=-SHSTK"
EOF
sudo systemctl daemon-reload
```

### 5. Start MongoDB

```bash
sudo systemctl enable mongod
sudo systemctl start mongod
```

### 6. Verify

```bash
systemctl status mongod
```

## Why this works

Kernel 6.19 enables hardware Shadow Stacks (SHSTK) on supported CPUs. MongoDB uses
a custom coroutine/stack-switching mechanism that is incompatible with SHSTK, causing
a segfault. Setting `GLIBC_TUNABLES=glibc.cpu.hwcaps=-SHSTK` tells glibc to disable
SHSTK for the process, avoiding the crash.

This workaround only affects the `mongod` process — SHSTK remains enabled system-wide
for all other programs.

## When to remove this workaround

Once MongoDB releases a version with SHSTK-compatible coroutines, remove the drop-in:

```bash
sudo rm /etc/systemd/system/mongod.service.d/shstk-fix.conf
sudo systemctl daemon-reload
sudo systemctl restart mongod
```
