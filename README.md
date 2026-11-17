# Arch Linux ARM on the ASUS Chromebook CM1406

Boot Arch Linux ARM with Hyprland from a USB stick on the ASUS Chromebook CM1406 (`google,tarkin`, MediaTek MT8189).
ChromeOS stays on the internal storage and is never touched: unplug the stick and the Chromebook boots ChromeOS as before.

No SSH and no second computer needed.

Version 1.50.2. Full details: [docs/REFERENCE.md](docs/REFERENCE.md). History: [CHANGELOG.md](CHANGELOG.md).

## What works

- USB boot in Developer Mode
- Built-in screen, keyboard and touchpad
- Wi-Fi and `pacman`
- Hyprland on the Mali-G57 GPU, started automatically at boot
- Bluetooth (reported by testers)

Not tested yet: the automatic first-boot setup, headphone switching, microphones, suspend, touchscreen.

## You need

- The Chromebook in Developer Mode
- A USB stick or USB SSD of 8 GB or more (it will be erased)
- A WPA2 Wi-Fi network (a phone hotspot works)

## Install

1. Download this repository as a zip into **Downloads**.

2. Open the ChromeOS terminal (`Ctrl+Alt+T`, then type `shell`) and unpack it:

   ```sh
   cd /var/tmp
   bsdtar -xf ~/MyFiles/Downloads/<zip-name>.zip
   ls
   ```

3. Plug in the stick. Open VT2 with `Ctrl+Alt+Refresh` and log in as `chronos`. Then run:

   ```sh
   cd /var/tmp/<unpacked-folder>
   sudo bash install.sh
   ```

   It downloads Arch Linux ARM, asks you to type the stick's name, writes the stick and asks for a password.
   If it gets interrupted, run the same command again: it resumes where it stopped.

4. Reboot with the stick plugged in. At the "OS verification is OFF" screen press `Ctrl+U`
   (or choose "Boot from external disk").

5. The first boot installs Hyprland, the GPU stack and sound by itself (20 to 60 minutes, keep it plugged in).
   The machine restarts once, then Hyprland starts at every boot.

To follow the first-boot setup:

```sh
tail -f /var/log/tarkin-firstboot.log
```

### Password

The password for `alarm` must be at least 8 characters. VT2 types as a QWERTY keyboard while the stick uses
the French layout, so use only these letters: `b c d e f g h i j k l n o p r s t u v x` (upper or lower case).
They are on the same keys on QWERTY and AZERTY.

### Options

| Option | What it does |
|---|---|
| `--dry-run` | Checks only, changes nothing |
| `--fresh` | Starts over instead of resuming |
| `--keymap us` | Keyboard layout (default `fr`) |
| `--no-desktop` | Terminal only, no Hyprland |
| `--wifi-ssid <name>` | Uses another Wi-Fi network |

Example: `sudo bash install.sh --keymap us`

## Keys

| Keys | Action |
|---|---|
| `Super+Enter` | Terminal |
| `Super+d` | App menu |
| `Super+e` | Files |
| `Super+q` | Close window |
| `Super+f` | Fullscreen |
| `Super+Shift+e` | Quit Hyprland |

## Useful commands

On the stick:

| Command | What it does |
|---|---|
| `sudo tarkin-wifi "Name"` | Connect to a Wi-Fi network |
| `sudo tarkin-diag` | Writes a report to send when something is broken |
| `tarkin-audio-test` | Tests the speakers, headphones and microphones |
| `sudo bash ~/upgrade-stick.sh` | Safe system upgrade |
| `sudo tarkin-session terminal` | Back to the plain terminal |
| `sudo tarkin-session desktop` | Back to Hyprland |

In ChromeOS VT2, from the unpacked folder:

| Command | What it does |
|---|---|
| `sudo bash scripts/check-usb.sh` | Checks the stick and shows why the last boot failed |
| `sudo bash scripts/repair-boot.sh` | Fixes USB boot after a ChromeOS update |

## Troubleshooting

| Problem | Fix |
|---|---|
| `sudo` does not work in the `Ctrl+Alt+T` terminal | Normal, use VT2 |
| Wrong characters in VT2 | VT2 is always QWERTY |
| It boots ChromeOS instead of the stick | Run `sudo bash scripts/repair-boot.sh` in VT2 |
| Black screen or stuck on the logo | Boot ChromeOS and run `sudo bash scripts/check-usb.sh` |
| The first-boot setup failed | Read `tail -n 40 /var/log/tarkin-firstboot.log`, then run `bash ~/install-hyprland.sh` (without `sudo`) |
| No internet on the stick | Try `sudo tarkin-dns --keep`, then `sudo tarkin-diag` |
| No sound | Run `tarkin-audio-test` and send a photo of the summary |
| `install.sh` finds no stick | Replug it in another port, without a hub |

More cases: [docs/REFERENCE.md](docs/REFERENCE.md#when-it-doesnt-work).

## Safety

- Use a spare stick. The installer refuses the internal disk.
- Only do this on a Chromebook you own. A school Chromebook may forbid Developer Mode.
- To undo everything, remove the stick and boot ChromeOS.

## Credits

Based on [zoan37's Omarchy / Arch Linux ARM Chromebook project](https://github.com/zoan37/lenovo-slim3-chromebook-omarchy).
MIT license, see [LICENSE](LICENSE).
