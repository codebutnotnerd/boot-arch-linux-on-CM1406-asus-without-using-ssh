# Arch Linux ARM on the ASUS Chromebook CM1406

These scripts put Arch Linux ARM on a USB stick and boot it on an ASUS Chromebook CM1406. You do it all from
the Chromebook. ChromeOS stays on the internal disk, untouched: unplug the stick and ChromeOS boots as before.

Version 1.60. More detail in [docs/REFERENCE.md](docs/REFERENCE.md), history in [CHANGELOG.md](CHANGELOG.md).

Only the CM1406 is supported (board `google,tarkin`, MediaTek MT8189, Mali-G57 GPU). The installer checks the
board and stops on anything else.

## What works and what doesn't

Works on my CM1406:

- USB boot in Developer Mode, screen, keyboard, touchpad
- Wi-Fi, `pacman`, speakers, Bluetooth audio (pick the headset once in `pavucontrol`)
- Hyprland 0.57.2 on the Mali-G57 GPU, started at boot without a login screen
- niri with the Vitrum Plus desktop, set up by hand with the same scripts
- Firefox on the GPU with `gpuapp`

Doesn't work, or not yet:

- The kernel is the ChromeOS one, re-signed. It is never replaced, and `tarkin-update` holds it back.
- Only the desktop uses the GPU. Apps render on the CPU unless started with `gpuapp`.
- No hardware video decoding. No suspend: the idle lock only turns the screen off.
- XFCE with SDDM is experimental. GDM goes black on the first key press, so it is off.

Not tried on the machine yet: the whole first boot from start to finish, `tarkin-desktop`, the screen lock,
`tarkin-update`, the headphone jack, the microphones, the touchscreen, the "stick in use" check, smooth mode
under niri and the 4-image Vulkan layer built by `install-gpuapp.sh`. The tests in `tests/` use mocks.

## What you need

- The Chromebook in Developer Mode
- A USB stick or USB SSD of 8 GB or more. It will be erased.
- Wi-Fi (a phone hotspot works)
- And a brain and electricity (optionnal)

## Install

1. In ChromeOS, download this repository as a zip into Downloads.

2. Open the ChromeOS terminal (`Ctrl+Alt+T`, type `shell`) and unpack it:

   ```sh
   cd /var/tmp
   bsdtar -xf ~/MyFiles/Downloads/boot-arch-linux-on-CM1406-v1.60.zip
   ```

3. Plug in the stick. Go to VT2 Shell (`Ctrl+Alt+Refresh`), log in as `root` and run:

   ```sh
   cd /var/tmp/boot-arch-linux-on-CM1406-v1.60
   sudo bash install.sh
   ```

   `sudo` only works in VT2. The installer downloads the rootfs, shows the stick, makes you type its name
   before erasing it, then asks for a password for the user `alarm`. If it stops, run the same command again
   and it carries on.

4. Reboot with the stick in. At "Your in devmode" press `Ctrl+U`.

5. First boot: a terminal appears. The stick installs the GPU stack and sound on its own (20 to 60 minutes,
   Wi-Fi needed, don't power off). Watch it with `tail -f /var/log/tarkin-firstboot.log`. No Wi-Fi?
   `sudo tarkin-wifi "Name"`. Then it restarts once, into the terminal. No desktop starts yet.

6. Choose the desktop, as `alarm`:

   ```sh
   tarkin-desktop
   ```

   It asks: 1) niri + Vitrum Plus, 2) Hyprland with the base config, 3) none. It installs what is missing
   and offers to restart. Without a menu: `tarkin-desktop --niri` or `tarkin-desktop --hyprland`.

To skip step 6, pass `--wm niri` or `--wm hyprland` to `install.sh`; the first boot then sets it up.

The password needs 8 characters or more. VT2 is always QWERTY and the stick defaults to French, so unless you
pass `--keymap us` only these letters are accepted: `b c d e f g h i j k l n o p r s t u v x`.

Other options: `--dry-run` (plan only), `--fresh` (start over), `--no-desktop` (terminal only),
`--wifi-ssid <name>`. All of them: `sudo bash install.sh --help`.

## Switching desktop, undo

`tarkin-desktop` can be run again any time. Changes apply at the next boot.

| Command | What it does |
|---|---|
| `tarkin-desktop --status` | What starts at boot, what is installed |
| `tarkin-desktop --hyprland` | Hyprland at boot |
| `tarkin-desktop --niri` | niri + Vitrum Plus at boot |
| `tarkin-desktop --none` | No desktop, terminal only |
| `tarkin-desktop --undo-niri` | Removes Vitrum Plus and niri, back to the terminal |

Under the hood: `--niri` runs `~/install-niri.sh` (niri with the EGL fix and Super+Shift+S), installs
`quickshell` and `qt6-declarative`, runs `~/install-vitrum-plus-niri-v10.sh --apply` and `--system-access
--apply`, then `sudo tarkin-wm niri`. `--undo-niri` runs `--no-system-access --apply`, `--rollback --apply`,
`sudo tarkin-wm hyprland` and `~/install-niri.sh --remove`. Packages stay; it prints the `pacman -Rs` line.
If niri fails to start, Hyprland starts instead.

## Using it

Hyprland keys: `Super+Enter` terminal, `Super+D` app menu, `Super+E` files, `Super+Q` close, `Super+F`
fullscreen, `Super+L` lock (also after 5 minutes idle), `Super+Shift+E` quit. On both desktops: `F6`/`F7`
brightness, `F8` keyboard light, `F13`/`F14` volume. In niri, `Super+Shift+S` takes a screenshot of a region
(clipboard and `~/Pictures/Screenshots`).

| Command | What it does |
|---|---|
| `sudo tarkin-wifi "Name"` | Connect to Wi-Fi |
| `sudo tarkin-update` | `pacman -Syu`, kernel held back |
| `tarkin-audio-test` | Test speakers, headphones, microphones |
| `blueman-manager`, `pavucontrol` | Bluetooth, sound output |
| `sudo tarkin-smooth on` | Smoother desktop: GPU at 526 MHz or more, compositor on the fast cores. Uses more power. `off` undoes it, `tarkin-smooth status` shows it. |
| `tarkin-firefox-widevine` | Optional Firefox DRM, see [docs/FIREFOX-WIDEVINE.md](docs/FIREFOX-WIDEVINE.md) |

## Apps on the GPU

`install-gpuapp.sh` adds `gpuapp`, which runs one program on the Mali-G57 through Mesa Zink and the Vulkan
driver of the ChromeOS `libmali`. It builds ARM's `vulkan-wsi-layer` with a patch from zoan37. Nothing else
changes: a program started without `gpuapp` stays on the CPU.

Run it as `alarm`, without `sudo`, in a terminal of the desktop:

```sh
bash ~/install-gpuapp.sh
gpuapp --check     # "apps on the GPU: yes (...)" or "no (reason)"
gpuapp firefox     # close the normal Firefox first
bash ~/install-gpuapp.sh --remove
```

There is also a "Firefox (GPU)" menu entry. The layer gives each window 4 buffers. With 2, Firefox froze under
niri. An older install is rebuilt when you run the script again; `--layer-rollback` puts the old one back.

Wayland programs only. X11 programs fail, Chromium and Electron fall back to the CPU, Qt Quick apps crash under
Zink.

## When something breaks

`sudo tarkin-diag` writes a report to `~/tarkin-diag-<date>.txt` (Wi-Fi names, passwords and MAC addresses are
masked; read it before sharing).

| Problem | What to do |
|---|---|
| ChromeOS boots instead of the stick | In VT2: `sudo bash scripts/repair-boot.sh` |
| Black screen or stuck on the logo | Boot ChromeOS, then in VT2: `sudo bash scripts/check-usb.sh` |
| `install.sh` finds no stick | Another port, no hub |
| "is in use, so it was not ..." | The installer lists what holds the stick. Close it or eject the stick, then retry. |
| First boot failed | A terminal shows the step, the reason and what to type. Log: `tail -n 40 /var/log/tarkin-firstboot.log` |
| "No usable libmali" | `bash ~/install-hyprland.sh --mali-source /path/to/libmali.so --no-autostart` |
| No internet | `sudo tarkin-dns --keep`, then `sudo tarkin-diag` |
| Black screen after `tarkin-display xfce` | [docs/DISPLAY-RECOVERY.md](docs/DISPLAY-RECOVERY.md) |

The `scripts/` commands run in ChromeOS VT2 from the unpacked folder. More in
[docs/REFERENCE.md](docs/REFERENCE.md#when-it-doesnt-work).

Use a spare stick; the installer refuses the internal disk. A school or work Chromebook may not allow
Developer Mode. To go back, remove the stick and boot ChromeOS.

## Credits and license

Based on zoan37's [lenovo-slim3-chromebook-omarchy](https://github.com/zoan37/lenovo-slim3-chromebook-omarchy):
the GPU probes, the EGL shim and the `vulkan-wsi-layer` patch come from there. `vulkan-wsi-layer` is by Arm
Limited and contributors. Vitrum Plus includes widgets from [MacShell-niri](https://github.com/frithTK/MacShell-niri)
(MIT, Rickky) and the [Open Runde](https://github.com/lauridskern/open-runde) font (SIL OFL 1.1).
MIT license, see [LICENSE](LICENSE).
