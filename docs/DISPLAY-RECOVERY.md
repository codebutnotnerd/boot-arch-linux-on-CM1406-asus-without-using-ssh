# Display recovery from ChromeOS (offline)

Use this when the stick boots to a black or unusable screen after `sudo tarkin-display xfce`
(SDDM + XFCE), or after any display-manager change, and you cannot reach a terminal on the stick.
It sets the next boot back to the graphical recovery terminal (`cage` + `foot`). There is no automatic
fallback: an SDDM that is "active" but black is not detected.

`scripts/repair-boot.sh` repairs USB boot (firmware flags, kernel partition); it does not touch the display owner.

## 1. Mount the stick's root partition from ChromeOS

Boot ChromeOS, plug the stick in, open VT2 (`Ctrl+Alt+Refresh`, login `chronos`) and find the stick.
Its second partition is labelled `ALARM`; check the size and label instead of guessing the name:

```sh
lsblk -o NAME,SIZE,TYPE,PARTLABEL,MOUNTPOINTS
sudo cgpt show -i 2 -l /dev/sdX        # must print ALARM
sudo mkdir -p /usr/local/alarm
sudo mount /dev/sdX2 /usr/local/alarm
```

Never use the internal disk (`/dev/mmcblk0`).

## 2. Select the recovery terminal for the next boot

From the unpacked repository folder, still in VT2:

```sh
cd /var/tmp/<unpacked-folder>
sudo bash scripts/recover-display.sh /usr/local/alarm
```

No program from the stick is executed. The script:

- refuses a mount point that is not a v1.40 Arch root (`/etc/arch-release`, `tarkin-console.service`,
  the console and `display-guard` must be there);
- removes `display-manager.service` only when it points to `sddm.service` or `gdm.service`, and the
  `sddm`/`gdm`/`tarkin-dm-fallback`/`tarkin-firstboot` links in `*.wants`/`*.requires` only when they point to
  the known units; anything else stops it without overwriting;
- writes `TARKIN_SESSION=terminal` into `/etc/tarkin/console.env` (other lines kept) and `terminal` into
  `/etc/tarkin/display-owner`, enables `tarkin-console.service` and sets `multi-user.target` as default;
- renames `firstboot.pending`/`firstboot.failed` to `*.disabled-for-recovery.<time>`, then syncs.

## 3. Check, unmount, reboot

```sh
ls -l /usr/local/alarm/etc/systemd/system/default.target \
      /usr/local/alarm/etc/systemd/system/multi-user.target.wants/tarkin-console.service
cat /usr/local/alarm/etc/tarkin/display-owner      # terminal
sudo umount /usr/local/alarm
```

Boot the stick. Expected: the graphical terminal (`cage` + `foot`), not a text tty. From there, choose again
explicitly, for example `sudo tarkin-display hyprland` and reboot. Do not restore the old SDDM links by hand.
If a first-boot marker was renamed (`*.disabled-for-recovery.*`), finish the setup by hand with
`bash ~/install-hyprland.sh` (as `alarm`, without `sudo`).
