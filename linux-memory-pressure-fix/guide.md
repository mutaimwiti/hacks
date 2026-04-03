# Linux memory pressure fix — prevent freezes on zram-only systems

Linux systems that rely solely on zram (compressed RAM) for swap can completely freeze
under memory pressure, requiring a hard reboot. This is common on Fedora and similar
distributions. The root cause is that zram doesn't provide extra memory — it just
compresses pages within the same RAM — so there's no safety valve when memory runs out.

Heavy workloads (IDEs, Docker, browsers, databases) can easily exhaust 16GB of RAM.

## Symptoms

- System freezes completely, requiring a power-button reboot
- Freezes occur during memory-intensive operations (switching IDE projects, starting
  Docker containers, running builds)
- `journalctl -b -1 -k --grep oom` shows OOM killer events in previous boots
- `journalctl --list-boots` shows frequent unexpected reboots

## Automated fix

```bash
chmod +x fix-memory-pressure.sh
sudo ./fix-memory-pressure.sh
```

Run with `--dry-run` first to preview changes:

```bash
sudo ./fix-memory-pressure.sh --dry-run
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--swap-size SIZE` | `8G` | Size of the disk-backed swap file |
| `--swappiness VALUE` | `60` | vm.swappiness value (1-100) |
| `--ide-heap SIZE_MB` | *(none)* | Set JetBrains IDE max heap in MB |
| `--dry-run` | | Show what would be done without making changes |

### Examples

```bash
# Apply defaults (8GB swap, swappiness=60)
sudo ./fix-memory-pressure.sh

# Custom swap size + lower IDE heap to 1536MB
sudo ./fix-memory-pressure.sh --swap-size 4G --ide-heap 1536

# Only adjust swap and swappiness
sudo ./fix-memory-pressure.sh --swappiness 50
```

## Manual fix

### 1. Create a disk-backed swap file

**On btrfs** (Fedora default):

```bash
sudo btrfs filesystem mkswapfile --size 8G /swapfile
sudo swapon /swapfile
```

**On ext4/xfs**:

```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Make it permanent:

```bash
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 2. Increase swappiness

The default on Fedora with zram is very low (around 10), meaning the kernel avoids
swapping until it's too late. A higher value lets the kernel page out idle memory early:

```bash
sudo sysctl vm.swappiness=60
echo 'vm.swappiness=60' | sudo tee /etc/sysctl.d/99-swappiness.conf
```

### 3. Lower JetBrains IDE heap (optional)

JetBrains IDEs default to a 2048MB max heap. If memory is tight, 1536MB is usually
sufficient. Edit the `.vmoptions` file for your IDE:

```bash
# Find it
find ~/.local/share/JetBrains -name "*.vmoptions" -path "*/bin/*"

# Change -Xmx2048m to -Xmx1536m
sed -i 's/^-Xmx.*/-Xmx1536m/' /path/to/ide64.vmoptions
```

Restart the IDE after changing.

## Why this works

zram compresses memory pages but still stores them in RAM. When all RAM is consumed,
the kernel has nowhere to evict pages to. The OOM killer gets invoked, but by that
point the system is often already thrashing so badly that it becomes unresponsive.

A disk-backed swap file gives the kernel an overflow area on disk. Combined with a
higher swappiness, the kernel proactively moves idle pages to disk before memory
becomes critical, preventing the freeze entirely.

## Verifying the fix

After applying, confirm with:

```bash
# Check swap is active
swapon --show

# Check swappiness
cat /proc/sys/vm/swappiness

# Monitor memory over time
watch -n 5 free -h
```

Reboot and verify the swap file persists:

```bash
sudo reboot
swapon --show
```
