# Intel i915 suspend/resume freeze fix — Meteor Lake / Arrow Lake

Intel Meteor Lake and Arrow Lake GPUs can lock up after resuming from suspend
(s2idle), freezing the entire system. The root cause is Panel Self Refresh (PSR)
interacting badly with the suspend/resume cycle, causing GuC (GPU microcontroller)
communication failures that stall the display compositor.

When gnome-shell's compositor stalls, input processing stops and the system appears
completely frozen, requiring a hard power-off.

## Symptoms

- System freezes minutes after waking from suspend (lid open / power button)
- `journalctl -b -1 -k` shows `i915` / `drm` errors like:
  - `GUC: CT: Unsolicited response message`
  - `GUC: CT: Failed to handle HXG message`
  - `[CRTC:148:pipe A] DSB 0 poll error`
  - `connector Unknown-1 leaked!`
- `gnome-shell` logs show `event processing lagging behind by Xms, your system is too slow`
- `last -x` shows `crash` entries after periods that included a suspend

## Automated fix

```bash
chmod +x fix-i915-suspend.sh
sudo ./fix-i915-suspend.sh
```

Run with `--dry-run` first to preview changes:

```bash
sudo ./fix-i915-suspend.sh --dry-run
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--disable-dc` | *(off)* | Also disable display C-states (try if PSR fix alone is not enough) |
| `--dry-run` | | Show what would be done without making changes |

## Manual fix

### 1. Disable PSR via modprobe

Create a modprobe config to disable Panel Self Refresh:

```bash
echo 'options i915 enable_psr=0' | sudo tee /etc/modprobe.d/i915-suspend-fix.conf
```

If that alone doesn't fix it, also disable display power states:

```bash
echo 'options i915 enable_psr=0 enable_dc=0' | sudo tee /etc/modprobe.d/i915-suspend-fix.conf
```

### 2. Rebuild initramfs

The i915 module loads early from initramfs, so the new config must be baked in:

**Fedora (dracut):**

```bash
sudo dracut --force
```

**Ubuntu/Debian:**

```bash
sudo update-initramfs -u
```

**Arch:**

```bash
sudo mkinitcpio -P
```

### 3. Reboot

```bash
sudo reboot
```

## Why this works

Panel Self Refresh (PSR) is a power-saving feature where the GPU tells the display
panel to refresh from its own framebuffer cache instead of continuously streaming
frames. On Meteor Lake / Arrow Lake, the PSR state machine doesn't cleanly
re-synchronize after a suspend/resume cycle, leaving the GuC (GPU microcontroller)
and the display engine out of sync.

This manifests as GuC communication timeouts (`Failed to handle HXG message`),
which block the DRM compositor pipeline. Since gnome-shell runs the Wayland
compositor in-process, a blocked GPU pipeline freezes all input handling and
rendering — making the system appear completely locked.

Disabling PSR trades a small amount of display power efficiency (typically 0.1-0.5W)
for reliable resume behavior.

## Verifying the fix

After rebooting, confirm PSR is disabled:

```bash
sudo cat /sys/module/i915/parameters/enable_psr
# Should output: 0
```

Check that the modprobe config is loaded:

```bash
cat /etc/modprobe.d/i915-suspend-fix.conf
```

Monitor for DRM errors over the next few suspend/resume cycles:

```bash
journalctl -b -k | grep -i 'i915.*error\|drm.*error'
```

The `DSB 0 poll error` at boot is cosmetic and harmless — it should not recur
after resume. The `connector Unknown-1 leaked!` warning is a known benign i915
driver message and can be ignored.
