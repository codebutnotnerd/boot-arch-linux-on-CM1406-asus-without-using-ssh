# Tarkin (ASUS CM1406, MT8189) — constats

Source : sorties collectées par l'utilisateur sur sa propre machine (ChromeOS, mode développeur). Aucun identifiant (HWID, UUID de partition, numéro de série, MAC) n'est reproduit ici. « Vu dans le DT » = nom de nœud seulement, propriétés non lues.

## Vérifié

| Sujet | Constat |
|---|---|
| Carte | `compatible` = `google,tarkin`, `mediatek,mt8189` ; modèle « Google Tarkin board » |
| SKU | `sku-id` = `0x1005` (4101), dans le groupe de configurations FIT `google,tarkin-sku4101/4103/4104/4106` |
| Noyau | 6.6.147 (ChromeOS) ; LSM actifs : capability, landlock, yama, **loadpin**, safesetid, chromiumos, selinux, bpf |
| Stockage | **eMMC** `mmcblk0` (116 Go), pas d'UFS actif ; p1 STATE (chiffré), p2/p4 noyaux 32 Mo, p3/p5 racines 4 Go, p12 EFI 64 Mo |
| Slot | Racine en `mmcblk0p5` → noyau actif en `p4` (KERN-B) |
| Noyau stock | FIT de ~14 Mo contenant `mt8189-skywalker-tarkin.dtb` et les overlays `tarkin-touchscreen`, `tarkin-kb-cm1406`, `tarkin-kb-cm1406-backlight`, `tarkin-ca-kb-cm1406`, `tarkin-ca-kb-cm1406-backlight` (et variantes cm1405/cm1505) |
| Repack | `futility vbutil_kernel --repack` avec les devkeys : exit 0, « Body verification succeeded », flags 0x1 |
| Dalle | EDID : code fabricant `CSW` (décodage), produit `0x143f` ; modes 1920x1200 et 1600x1200 ; fabricant différent d'Obiwan (AUO) |
| Audio | Carte ALSA `mt8189_rt5650` ; pas de nœud `sound/compatible` à la racine |
| Entrées | `cros_ec`, `cros_ec_buttons`, `gpio-keys`, `hid-over-i2c 04F3:31C6 Touchpad`, jacks casque/DP/HDMI ; aucun tactile listé |
| Batterie | `sbs-10-000f` (adresse 0x0f) ; ports USB-C via `ucsi` sur l'EC (SPI) |
| Wi-Fi / BT | PCIe `14c3:7925` (MT7925) derrière un pont `14c3:8189` ; USB `13d3:3602` (probablement le Bluetooth, non confirmé) |
| Outils ChromeOS | Présents : cgpt, futility, bsdtar, dtc, mkfs.ext4, chroot, curl. **Absents : python3, git, dumpimage, mosys** |
| Montage | `/usr/local` (stateful chiffré) sans `noexec` ; `mount` fonctionne |

## Vu dans le DT (nœuds, propriétés non lues)

- `i2c@11b20000/audio-codec@1a` (avec `cbj-sleeve-gpio`) et un nœud `/audio-codec` avec `enable-gpios`
- `i2c@11f30000/trackpad@2c` et `trackpad@15` (un seul touchpad détecté : 04F3:31C6)
- `spi@11010800/ec@0` et `spi@11011800/ec@0` (ce dernier avec `boot0-gpios` et `reset-gpios`)
- `mmc@11230000`, `mmc@11240000` (avec `cd-gpios`) ; `ufshci@112b0000` présent mais eMMC en service
- `pwm@1100e000` + `/backlight`, `edp-tx@11b70000`, `dp-tx@11b60000`, `pcie@112f0000`
- `i2c@11d73000/ite61620@58`, `i2c@11d70000/tpm@50`, `i2c@11d72000/proximity@28`

## Non établi

- Le démarrage réel depuis la clé USB.
- Le codec et l'ampli audio exacts (seul le nom de la carte `mt8189_rt5650` est connu), et l'existence d'un UCM adapté.
- La résolution native confirmée et les GPIO de la dalle.
- Le fonctionnement du GPU avec les composants hérités d'Obiwan.
- Le rôle de `google,tarkin-sku2147483647` dans le FIT (supposé : configuration générique).
- Un `mt8189-tarkin.dts` mainline : non écrit.
