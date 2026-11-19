# Arch Linux ARM on the ASUS Chromebook CM1406

Scripts that put Arch Linux ARM with Hyprland on a USB stick and boot it on an ASUS Chromebook CM1406.
Everything is done on the Chromebook itself: no SSH, no second computer. ChromeOS stays on the internal
storage and is not modified; unplug the stick and the Chromebook boots ChromeOS as before.

Version 1.40. Details are in [docs/REFERENCE.md](docs/REFERENCE.md), history in [CHANGELOG.md](CHANGELOG.md).

## Hardware

Only the ASUS Chromebook CM1406 (board `google,tarkin`, MediaTek MT8189, Mali-G57 GPU). The installer checks
the board name and stops on anything else.

## Status

Works on my CM1406:

- USB boot in Developer Mode, built-in screen, keyboard and touchpad
- Wi-Fi and `pacman`
- Hyprland 0.57.2 rendering on the Mali-G57, started at boot without a login screen
- Speakers
- Bluetooth audio (one JBL headset; you may have to pick it once in `pavucontrol`)
- Firefox on the GPU through `gpuapp` (see [Applications on the GPU](#applications-on-the-gpu))

Limits:

- The stick runs the ChromeOS kernel, re-signed with the developer keys, with its own modules. It is never
  replaced by an Arch kernel, and `tarkin-update` holds the kernel packages back.
- Only Hyprland uses the GPU. Applications render on the CPU (Mesa llvmpipe) unless you start them with `gpuapp`.
- No hardware video decoding.
- No suspend. The idle lock only turns the screen off.
- XFCE with SDDM is experimental. The SDDM login screen has never been tried on the machine, and the GDM one
  goes black on the first key press, so GDM is off by default.

Written but not yet tried on the machine: the automatic first-boot setup from start to finish, finding the GPU
driver on a freshly made stick, the screen lock, `tarkin-update`, headphone jack switching, the microphones.
The touchscreen and Netflix have not been tried either. The tests in `tests/` run against mocks, not the hardware.

## What you need

- The Chromebook in Developer Mode
- A USB stick or USB SSD, 8 GB or more. It will be erased.
- A WPA2 Wi-Fi network (a phone hotspot is fine)

## Install

1. In ChromeOS, download this repository as a zip into Downloads.

2. Open the ChromeOS terminal (`Ctrl+Alt+T`, then type `shell`) and unpack it:

   ```sh
   cd /var/tmp
   bsdtar -xf ~/MyFiles/Downloads/<zip-name>.zip
   ls
   ```

3. Plug in the stick. Switch to VT2 with `Ctrl+Alt+Refresh`, log in as `chronos`, and run:

   ```sh
   cd /var/tmp/<unpacked-folder>
   sudo bash install.sh
   ```

   `sudo` only works in VT2, not in the `Ctrl+Alt+T` terminal. The installer downloads the Arch Linux ARM
   rootfs, shows the stick and makes you type its name before erasing it, then asks for a password for the
   user `alarm`. If it is interrupted, run the same command again and it resumes.

4. Reboot with the stick plugged in. At the "OS verification is OFF" screen press `Ctrl+U`, or choose
   "Boot from external disk".

5. The first boot installs Hyprland, the GPU stack and sound (20 to 60 minutes, needs Wi-Fi, do not power
   off). The machine then restarts once and Hyprland starts at every boot. To watch it:

   ```sh
   tail -f /var/log/tarkin-firstboot.log
   ```

### Password

At least 8 characters. VT2 is always QWERTY while the stick defaults to the French layout, so unless you pass
`--keymap us` the installer only accepts the letters that sit on the same keys on both:
`b c d e f g h i j k l n o p r s t u v x`, upper or lower case.

### Installer options

| Option | Effect |
|---|---|
| `--dry-run` | Run the checks and print the plan. Nothing is downloaded or written. |
| `--fresh` | Ignore an interrupted install and start over |
| `--keymap <layout>` | Keyboard layout on the stick (`fr` by default; `us`, `de`, ...) |
| `--no-desktop` | Terminal only, no first-boot Hyprland setup |
| `--wifi-ssid <name>` | Use this Wi-Fi network instead of the one saved in ChromeOS |

Example: `sudo bash install.sh --keymap us`. `sudo bash install.sh --help` lists the rest.

## Using it

| Keys | Action |
|---|---|
| `Super+Enter` | Terminal (foot) |
| `Super+D` | Application menu (fuzzel) |
| `Super+E` | File manager |
| `Super+Q` | Close the window |
| `Super+F` | Fullscreen |
| `Super+L` | Lock. Also locks after 5 minutes idle; the screen turns off 30 seconds later. |
| `Super+Shift+E` | Quit Hyprland |

Commands on the stick, as `alarm`:

| Command | Effect |
|---|---|
| `sudo tarkin-wifi "Name"` | Connect to a Wi-Fi network |
| `sudo tarkin-update` | Full `pacman -Syu` that keeps the kernel packages back |
| `sudo bash ~/upgrade-stick.sh` | The same update with extra protections for slow USB sticks |
| `tarkin-audio-test` | Step-by-step test of speakers, headphones and microphones |
| `blueman-manager`, `pavucontrol` | Pair Bluetooth devices, choose the sound output |
| `sudo tarkin-display hyprland` | Hyprland at the next boot (the default) |
| `sudo tarkin-display terminal` | A plain terminal (cage + foot) at the next boot |
| `sudo tarkin-display xfce` | XFCE at the next boot, after `bash ~/install-xfce.sh` (experimental) |
| `tarkin-firefox-widevine` | Optional Firefox DRM setup, see [docs/FIREFOX-WIDEVINE.md](docs/FIREFOX-WIDEVINE.md) |

`tarkin-display` never restarts the running screen. Run `sudo reboot` to switch.

## Applications on the GPU

Optional. `install-gpuapp.sh` installs a launcher, `gpuapp`, that runs one program on the Mali-G57 through
Mesa Zink and the Vulkan driver inside the ChromeOS `libmali`. It builds ARM's `vulkan-wsi-layer` on the stick
with a patch from zoan37. Nothing is registered system-wide: a program started without `gpuapp` renders on the
CPU as before.

Run it as `alarm`, without `sudo`, in a terminal of the Hyprland desktop:

```sh
bash ~/install-gpuapp.sh
gpuapp --check            # prints "apps on the GPU: yes (...)" or "no (reason)"
gpuapp firefox            # close the normal Firefox first
bash ~/install-gpuapp.sh --remove
```

There is also a "Firefox (GPU)" menu entry when Firefox is installed.

On the CM1406 the script installed and `gpuapp --check` answered
`apps on the GPU: yes (zink Vulkan 1.4(Mali-G57 (ARM_PROPRIETARY)))`; Firefox reported WebRender on that
renderer in `about:support`. I have no benchmark numbers. `--remove` has only been run against mocks.

Wayland programs only. X11 programs fail, Chromium and Electron applications fall back to the CPU, Qt Quick
applications crash under Zink, and video is still decoded on the CPU.

## When something breaks

On the stick, `sudo tarkin-diag` writes a report to `~/tarkin-diag-<date>.txt`. Wi-Fi names, passwords and MAC
addresses are masked, but read it before posting it anywhere.

| Problem | What to do |
|---|---|
| It boots ChromeOS instead of the stick | In VT2: `sudo bash scripts/repair-boot.sh` |
| Black screen, or stuck on the logo | Boot ChromeOS, then in VT2: `sudo bash scripts/check-usb.sh` |
| `install.sh` finds no stick | Plug it into another port, without a hub |
| The first-boot setup failed | `tail -n 40 /var/log/tarkin-firstboot.log`, then `bash ~/install-hyprland.sh` (no `sudo`) |
| "No usable libmali" during the first boot | Copy a working `libmali.so` to the stick, then `bash ~/install-hyprland.sh --mali-source /path/to/libmali.so` |
| No internet on the stick | `sudo tarkin-dns --keep`, then `sudo tarkin-diag` |
| No sound | `tarkin-audio-test` |
| Black screen after `tarkin-display xfce` | [docs/DISPLAY-RECOVERY.md](docs/DISPLAY-RECOVERY.md), from ChromeOS |
| Wrong characters in VT2 | VT2 is always QWERTY |

The `scripts/` commands run in ChromeOS VT2 from the unpacked folder. More cases are in
[docs/REFERENCE.md](docs/REFERENCE.md#when-it-doesnt-work).

## Safety

Use a spare stick; the installer refuses the internal disk. Only do this on a Chromebook you own: a managed
(school or work) Chromebook may not allow Developer Mode. To go back, remove the stick and boot ChromeOS.

## Credits

Based on zoan37's [lenovo-slim3-chromebook-omarchy](https://github.com/zoan37/lenovo-slim3-chromebook-omarchy):
the GPU probes, the EGL shim and the `vulkan-wsi-layer` patch come from that project. `vulkan-wsi-layer` is by
Arm Limited and contributors. MIT license, see [LICENSE](LICENSE).
