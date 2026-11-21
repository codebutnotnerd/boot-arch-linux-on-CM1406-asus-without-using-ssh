# System updates and Firefox DRM

## Update the stick

Inside the installed Arch system:

```sh
sudo tarkin-update
```

No arguments are needed or accepted. Review pacman's transaction and answer its normal prompts.
The command runs a full `pacman -Syu`, not a database-only refresh. It ignores `linux`, `linux-*`,
`linux-aarch64`, `linux-aarch64-headers`, plus installed packages owning kernel images under `/boot`,
modules under `/lib/modules` or `/usr/lib/modules`, and headers under `/usr/src`.
This also covers custom local package names with those files. The base installer copies the signed
ChromeOS kernel to partition 1 and its matching modules into the root filesystem; those are not
replaced by Arch's generic kernel. No force flags or unattended confirmations are used.
Review any replacement/removal prompts carefully; do not approve replacing preserved kernel packages.
The command returns pacman's update exit status; failure is not reported as success.

An interrupted transaction or file conflict needs diagnosis before retrying. Do not use `--overwrite`,
`--nodeps`, or a database-only `-Sy` to work around it. There is no background updater.

## Configure an already installed Widevine package

This is optional and is never called by first boot. Firefox, Python 3 and the AUR `widevine` package
must already be installed. Run as the normal user who uses Firefox, **not with sudo**:

1. Start Firefox once to create a profile; then close all Firefox windows and processes.
2. Run:

   ```sh
   tarkin-firefox-widevine
   ```

3. Authenticate the requested sudo command, which only updates `MOZ_GMP_PATH` in `/etc/environment`.
   Reboot, enable **Play DRM-controlled content** in Firefox settings, then test Spotify playback.

`/etc/environment` is read by login sessions (PAM: SDDM/XFCE, GDM). The Hyprland started by
`tarkin-console` is not a login session, so the console reads only the line this helper writes,
without running the file: exactly one `MOZ_GMP_PATH="/opt/WidevineCdm/..."` line in a root-owned
`/etc/environment`, pointing to a directory with `manifest.json` and `libwidevinecdm.so` that is owned
by root and not writable by group or others. It then exports `MOZ_GMP_PATH` to Hyprland (and the
plain terminal) from the next start. Any other form, a second line, another location or a missing file
exports nothing; Firefox then has only the profile copies below. A package that installs outside
`/opt/WidevineCdm` is not exported. To see what a running Firefox got:
`tr '\0' '\n' < /proc/$(pgrep -n firefox)/environ | grep MOZ_GMP_PATH`.

The helper discovers the installed Firefox manifest and version through `pacman -Ql widevine`;
it does not assume version `4.10.2710.0` or hard-code the old `/opt/WidevineCdm` layout.
It copies the manifest directory with symlinks dereferenced into each configured profile's
`gmp-widevinecdm/<installed-version>/`. Valid same/newer profile versions are kept untouched.
Both `profiles.ini` and `installs.ini` are read under `~/.mozilla/firefox` and
`~/.config/mozilla/firefox`, including absolute profile paths. A configured missing profile or an
incomplete target directory produces an actionable error, not a success message.
Snap/Flatpak Firefox profiles are not supported by this host-package helper.

**New Firefox profile later:** start it once, close Firefox and rerun `tarkin-firefox-widevine`
as that profile's user. Rerun after updating the Widevine package too. If installation succeeds for
one profile but fails for another, fix the reported problem and rerun; completed valid copies are retained.
This helper does not download or bundle proprietary binaries. Spotify worked with the manual
procedure on the CM1406; this automated path still needs device validation. Netflix is untested.

## Optional build from a reviewed AUR checkout

AUR recipes execute code. Review the exact commit and every tracked file, including PKGBUILD,
`.install` scripts, patches and source URLs, before running the build. This project does not claim
that an arbitrary current AUR revision has been audited and does not ship a fabricated commit SHA.
Prefer a cached checkout at a previously reviewed commit. The helper accepts only a clean checkout
at the supplied full 40-character SHA and verifies upstream source checks with makepkg.

If you need to obtain a checkout, first update and install the review tools (normal sudo prompts):

```sh
sudo tarkin-update
sudo pacman -S --needed git python
mkdir -p ~/aur
cd ~/aur
git clone https://aur.archlinux.org/widevine.git
cd widevine
git log -1 --format=fuller
git ls-files
```

Inspect every file listed by `git ls-files` with your editor before approving that revision.
If the checkout already contains build artifacts, use a fresh checkout rather than deleting files
blindly. After review, record its exact commit and run, still as the normal Firefox user:

```sh
revision=$(git rev-parse HEAD)
tarkin-firefox-widevine --build "$PWD" "$revision"
```

For a cached recipe use its already reviewed full SHA instead of deriving a new one blindly.
The helper requires `HEAD` to equal that SHA and rejects tracked changes and untracked files.
It runs `sudo tarkin-update` first; any failure stops the build. It then interactively installs
`base-devel git python squashfs-tools firefox`, runs `makepkg --verifysource`, and runs
`makepkg -si` **without sudo**. Only pacman's normal installation steps request sudo authentication;
no passwordless first-boot rule is added and no source checks are skipped. If the recipe requires
additional dependencies or upstream source validation fails, inspect the error and review the fix;
do not bypass checks. Profile setup follows only after a successful build/install.
