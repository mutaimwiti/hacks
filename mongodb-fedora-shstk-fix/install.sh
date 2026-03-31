#!/usr/bin/env bash
set -euo pipefail

# MongoDB on Fedora 43+ (kernel 6.19+) crashes with SIGSEGV due to
# hardware Shadow Stack (SHSTK) incompatibility. This script does a
# clean install of MongoDB 8.0 with the SHSTK workaround applied.

echo "==> Stopping MongoDB service..."
sudo systemctl stop mongod 2>/dev/null || true
sudo systemctl disable mongod 2>/dev/null || true

echo "==> Stopping any existing mongodb Podman container..."
podman stop mongodb 2>/dev/null || true
podman rm mongodb 2>/dev/null || true

echo "==> Removing existing MongoDB packages..."
sudo dnf remove -y mongodb-org mongodb-org-server mongodb-org-mongos \
  mongodb-org-database mongodb-org-tools mongodb-org-database-tools-extra \
  mongodb-mongosh mongodb-database-tools 2>/dev/null || true

echo "==> Cleaning up data, logs, config, and repo..."
sudo rm -rf /var/lib/mongo /var/log/mongodb /tmp/mongodb-27017.sock
sudo rm -f /etc/yum.repos.d/mongodb-org-*.repo
sudo rm -f /etc/mongod.conf
sudo rm -rf /etc/systemd/system/mongod.service.d

echo "==> Removing leftover mongod user/group..."
sudo userdel mongod 2>/dev/null || true
sudo groupdel mongod 2>/dev/null || true

echo "==> Adding MongoDB 8.0 repo..."
sudo tee /etc/yum.repos.d/mongodb-org-8.0.repo > /dev/null <<'EOF'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF

echo "==> Installing MongoDB 8.0..."
sudo dnf install -y mongodb-org

echo "==> Applying Shadow Stack (SHSTK) workaround..."
sudo mkdir -p /etc/systemd/system/mongod.service.d
sudo tee /etc/systemd/system/mongod.service.d/shstk-fix.conf > /dev/null <<'EOF'
[Service]
Environment="GLIBC_TUNABLES=glibc.cpu.hwcaps=-SHSTK"
EOF
sudo systemctl daemon-reload

echo "==> Starting MongoDB..."
sudo systemctl enable mongod
sudo systemctl start mongod

echo "==> Verifying..."
sleep 3
if systemctl is-active --quiet mongod; then
  echo ""
  echo "Done! MongoDB 8.0 is running with the SHSTK workaround."
  echo "It will auto-start on boot."
else
  echo ""
  echo "MongoDB failed to start. Debug with: journalctl -u mongod -n 30"
  exit 1
fi
