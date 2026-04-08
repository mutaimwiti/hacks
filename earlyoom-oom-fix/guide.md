# earlyoom OOM fix — prevent system freezes from memory exhaustion

Linux can completely freeze when RAM and swap are exhausted, requiring a hard
power-off. The kernel's built-in OOM killer activates too late — by the time
it runs, the system is often thrashing so badly that it can't execute the kill.

earlyoom monitors available memory from userspace and kills the heaviest
process early, while the system is still responsive. This turns a hard freeze
into a killed browser tab or container.

## Symptoms

- System freezes completely during memory-intensive work (Docker builds,
  running many containers, compiling, opening large projects in an IDE)
- Hard power-off is the only recovery
- `journalctl -b -1` shows no orderly shutdown — logs just stop
- `journalctl --list-boots` shows frequent unexpected reboots
- Previous boot's journal file may be truncated (wasn't flushed before crash)

## Automated fix

```bash
chmod +x fix-earlyoom.sh
sudo ./fix-earlyoom.sh
```

Run with `--dry-run` first to preview changes:

```bash
sudo ./fix-earlyoom.sh --dry-run
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--mem-thresh PERCENT` | `15` | SIGTERM when free RAM drops below this % |
| `--swap-thresh PERCENT` | `10` | SIGTERM when free swap drops below this % |
| `--notify` | *(off)* | Enable desktop notifications when a process is killed |
| `--dry-run` | | Show what would be done without making changes |

SIGKILL thresholds are automatically set to half the SIGTERM thresholds.

### Examples

```bash
# Apply defaults (15% mem, 10% swap)
sudo ./fix-earlyoom.sh

# More aggressive — act earlier on a 16GB machine
sudo ./fix-earlyoom.sh --mem-thresh 20

# With desktop notifications
sudo ./fix-earlyoom.sh --notify
```

## Manual fix

### 1. Install earlyoom

```bash
sudo dnf install earlyoom
```

### 2. Configure thresholds

Edit `/etc/default/earlyoom`:

```bash
EARLYOOM_ARGS="-m 15,7 -s 10,5 --avoid '(^|/)(init|systemd|sshd|dockerd|containerd|gnome-shell|Xorg|Xwayland|plasmashell|pipewire|wireplumber)$' --prefer '(^|/)(Web Content|firefox-bin|chrome|chromium|electron|node|java|bundle)$'"
```

- `-m 15,7` — SIGTERM at 15% free RAM (~2.4 GB on 16 GB), SIGKILL at 7%
- `-s 10,5` — SIGTERM at 10% free swap, SIGKILL at 5%
- `--avoid` — never kill system daemons, Docker, or the desktop compositor
- `--prefer` — kill browser tabs, Electron apps, and JVM processes first

Both memory **and** swap must fall below their thresholds before earlyoom acts.

### 3. Disable systemd-oomd (if active)

earlyoom and systemd-oomd conflict — only one should run:

```bash
sudo systemctl disable --now systemd-oomd
```

### 4. Enable earlyoom

```bash
sudo systemctl enable --now earlyoom
```

## Why this works

The kernel OOM killer runs in kernel context after memory allocation has
already failed. At that point the system is deep in direct reclaim — scanning
page tables, waiting on I/O, retrying allocations — and often too slow to
even schedule the kill. The result is a frozen system.

earlyoom runs as a lightweight userspace daemon (~2 MB RSS) that polls
`/proc/meminfo` every second. When available memory drops below the
configured threshold, it sends SIGTERM to the process with the highest
`oom_score` — the kernel's own estimate of which process to sacrifice.
If the process doesn't exit within a few seconds, earlyoom escalates to
SIGKILL.

Because earlyoom acts while the system still has ~2 GB of free RAM (at the
15% threshold on 16 GB), the kill executes quickly and the system remains
responsive.

## Relationship to other fixes

This fix complements the [linux-memory-pressure-fix](../linux-memory-pressure-fix/):

| Fix | What it does |
|-----|-------------|
| **linux-memory-pressure-fix** | Adds disk-backed swap so the kernel has overflow space |
| **earlyoom-oom-fix** | Kills runaway processes before swap is exhausted |

Apply both for best protection. The swap file buys time during memory spikes;
earlyoom is the backstop when even swap isn't enough.

## Verifying the fix

```bash
# Check earlyoom is running
systemctl status earlyoom

# View recent earlyoom log entries
journalctl -u earlyoom -n 20

# Watch earlyoom in real time (shows memory polling)
journalctl -u earlyoom -f

# Search for past kills
journalctl -u earlyoom | grep -E "Sending SIGTERM|SIGKILL"
```

## Tuning

On a 16 GB machine running Docker, a JetBrains IDE, and a browser:

| Threshold | Free RAM at trigger | Recommendation |
|-----------|-------------------|----------------|
| 10% (default) | ~1.5 GB | May be too late — system already sluggish |
| 15% (script default) | ~2.4 GB | Good balance for most workloads |
| 20% | ~3.2 GB | Conservative — use if running many containers |

If earlyoom kills processes too aggressively, lower the threshold. If the
system still freezes, raise it.
