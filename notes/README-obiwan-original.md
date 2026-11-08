# Omarchy / Arch Linux ARM sur ASUS Chromebook CM14 (MT8189 / Skywalker)

> [!WARNING]
> **État réel.** Ce dépôt a été validé sur **une seule unité** : famille **Skywalker, variante Obiwan**
> (rev 3, SKU 196620), SoC **MediaTek MT8189**, stockage **UFS**, dalle 1920×1200. Les autres variantes
> (par exemple **Tarkin / tarkin-futr**) ne sont **pas supportées telles quelles** : le DTS, l'audio, la dalle,
> le Wi-Fi et les GPIO sont écrits pour Obiwan. Les anciens tableaux de spécifications (MT8186, Mali-G52,
> eMMC 64 Go) étaient faux et ont été retirés ; la référence est `notes/`.

## 0. Quel chemin pour quelle machine

| Machine | Chemin | Fiabilité |
|---|---|---|
| Obiwan rev3 SKU 196620 | Noyau mainline (`notes/mainline-*.md`) ou noyau ChromeOS 6.6 | Validé par l'auteur |
| **Autre variante Skywalker (Tarkin-futr…)** | **Chemin A** : réutiliser le noyau ChromeOS d'origine de la machine | Seule voie réaliste sans DTS dédié |
| Autre variante, noyau mainline | **Chemin B** : écrire un DTS à partir du DTB stock | Travail de portage, non validé |

Le noyau ChromeOS d'origine contient déjà le bon DTB pour ta carte. Le chemin A le réempaquette et ne touche
qu'au userland (Arch Linux ARM + Omarchy) : c'est pourquoi il peut marcher sur une variante inconnue.

## 1. Identifier la machine (obligatoire, lecture seule)

Mode développeur ChromeOS, shell (`Ctrl+Alt+⟳` ou crosh → `shell`), en root :

```sh
sudo bash scripts/identify-device.sh        # écrit ~/cm14-report/
```

Le script lit `/proc/device-tree/compatible` (ex. `google,tarkin-…`), détecte le disque racine (eMMC `mmcblkN`
ou UFS `sdX`), liste le GPT, extrait le DTB en cours et le FIT du noyau stock. Il ne collecte ni HWID, ni
numéro de série, ni adresse MAC. Gardez `report.txt`, `running.dts` et `stock-fit-layout.txt` : ils servent
de référence pour tout le reste.

## 2. Chemin A : Arch Linux ARM + Omarchy avec le noyau ChromeOS d'origine

À exécuter **sur le Chromebook**, en mode développeur, avec une clé USB (tout son contenu sera effacé) :

```sh
sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0
lsblk -o NAME,SIZE,RM,TRAN            # repérer la clé : RM=1, TRAN=usb
sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh /dev/sdX
```

Sans `--kernel` ni `artifacts/kernel.fit`, `install-usb.sh` détecte ChromeOS (`rootdev`), prend le noyau stock
de `KERN-A`, le réempaquette avec les clés développeur et l'écrit sur la clé. Branchez la clé, redémarrez,
**Ctrl+U** à l'écran « OS verification is OFF ».

Limites du noyau ChromeOS (voir `notes/gpu-*.md`, `notes/desktop-*.md`) : pas de console VT/fbcon (écran noir
tant que le compositeur ne pilote pas le DRM), pas de swap sur disque, GPU via libmali + shims. Les fichiers
`port/quigon/root/…` sont écrits pour Obiwan : audio (UCM RT5682S/RT1019P), touchpad, batterie peuvent demander
des ajustements sur Tarkin (`aplay -l`, `libinput list-devices`).

Retour arrière : la clé ne touche pas au disque interne ; retirez-la et redémarrez.

## 3. Chemin B : noyau mainline pour une autre variante (portage)

1. Comparez `running.dts` (étape 1) aux fichiers `port/quigon/mainline/*.dts*` : dalle eDP, pont d'affichage,
   audio, Wi-Fi/BT, GPIO, régulateurs.
2. Copiez `mt8189-quigon.dts` vers `mt8189-<variante>.dts`, mettez le `compatible` exact de votre carte et
   corrigez les nœuds qui diffèrent.
3. Construisez le FIT avec vos chaînes de compatibilité (séparées par `;`, telles qu'affichées par
   `identify-device.sh`) :

```sh
ALLOW_ANY_DTB=1 EXTRA_COMPAT_LIST="<compat1>;<compat2>;<compat3>" \
  bash scripts/build-kernel-fit.sh <Image> <votre.dtb> artifacts/kernel.fit
```

4. Signez et gravez sur **USB uniquement** (`install-usb.sh --kernel artifacts/kernel.fit`), puis testez.
   N'utilisez pas l'installation interne tant que l'USB ne démarre pas proprement.

Dépendances du noyau : linux-next + séries MT8189 non fusionnées + patches de `port/quigon/patches/`
(voir `notes/mainline-20261009.md`). Aucun noyau précompilé n'est fourni (`artifacts/` est vide).

## 4. Prérequis pour compiler (chemin B)

Utilisez un hôte Linux ARM64 ou x86_64 avec les outils de compilation croisée :

```sh
# Arch Linux (les noms de paquets peuvent varier selon le dépôt)
sudo pacman -S --needed base-devel git bc bison flex openssl \
  aarch64-linux-gnu-gcc dtc lz4 uboot-tools vboot-utils

git clone --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git \
  "$HOME/linux-next"
```

Le script exige `aarch64-linux-gnu-gcc`, `make`, `git`, `nproc`, `lz4` et
`mkimage` (`uboot-tools`). Pour MT8189, il applique une liste explicite de
patchs; un patch manquant ou qui ne s'applique plus arrête le build. Il ne
choisit pas silencieusement un patch expérimental.

## 5. Compilation du noyau et de l'image FIT

Pour la variante MT8186 (choix par défaut) :

```sh
SOC=mt8186 bash scripts/build-mt8186-kernel.sh "$HOME/linux-next"
```

Pour la variante MT8189 :

```sh
SOC=mt8189 bash scripts/build-mt8186-kernel.sh "$HOME/linux-next"
```

Le résultat est `artifacts/kernel.fit`, ignoré par Git. Les modules sont
installés dans `artifacts/modules-mt8186/` ou `artifacts/modules-mt8189/`.
Le script choisit le DTB du SoC demandé et refuse de le remplacer par l'autre.

Pour fabriquer le FIT à partir d'un noyau déjà compilé :

```sh
SOC=mt8186 bash scripts/build-kernel-fit.sh \
  "$HOME/linux-next/build-cm14-mt8186/arch/arm64/boot/Image" \
  "$HOME/linux-next/build-cm14-mt8186/arch/arm64/boot/dts/mediatek/mt8186-corsola-quigon.dtb" \
  artifacts/kernel.fit
```

L'image est compressée en LZ4 legacy pour Depthcharge et la sortie est refusée
si elle atteint 32 MiB. La chaîne `compatible` commune doit rester cohérente
entre les DTS, le fichier FIT de référence et le descripteur généré par le
script :

```text
google,quigon-sku0
google,quigon-sku1
google,quigon-sku512
google,quigon
google,obiwan-rev3-sku196620
google,obiwan-rev3
google,obiwan-sku196620
google,obiwan
google,corsola
mediatek,mt8189
mediatek,mt8186
```

## 6. Signature ChromeOS / Depthcharge

Installer `vboot-utils` et disposer des clés de développement ChromeOS
(`kernel.keyblock` et `kernel_data_key.vbprivk`). Le script
`install/sign-kernel.sh` cherche les clés dans `/usr/share/vboot/devkeys/`,
`devkeys/` ou un répertoire passé avec `--keys-dir`. Les clés de développement
ne sont pas des clés de production et ne doivent pas être commitées.

```sh
sudo bash install/sign-kernel.sh \
  --vmlinuz artifacts/kernel.fit \
  --out /tmp/kern-usb.bin \
  --target usb \
  --arch aarch64 \
  --flags 0x1
```

La commande `vbutil_kernel --pack` utilisée par le script comprend le
keyblock, la clé privée, la ligne de commande, un petit fichier bootloader
factice requis par l'outil et `--vmlinuz artifacts/kernel.fit`; le résultat est
ensuite vérifié avec `vbutil_kernel --verify`. Pour un appel manuel, reprendre
ces mêmes paramètres et employer `futility vbutil_kernel` si le système ne
fournit pas `vbutil_kernel` directement.

## 7. Préparer une clé USB de démarrage

La partition de noyau **n'est pas FAT32**. Depthcharge recherche un GPT ChromeOS :

1. Partition 1 : type ChromeOS `kernel`, 64 MiB, image noyau signée.
2. Partition 2 : partition de données contenant Arch Linux ARM en ext4,
   étiquette `OMARCHY_ROOT`.

Télécharger l'archive ARM64 officielle ainsi que son fichier `.md5` correspondant,
puis les placer localement (par exemple dans un répertoire privé hors du dépôt).
Le script vérifie le checksum avant l'extraction. Il efface entièrement la clé.

```sh
# Remplacer /dev/sdX par le disque USB vérifié avec lsblk.
sudo env CONFIRM_ERASE=/dev/sdX SOC=mt8186 \
  bash install/install-usb.sh \
  --kernel artifacts/kernel.fit \
  --alarm "$HOME/ArchLinuxARM-aarch64-latest.tar.gz" \
  /dev/sdX
```

Le fichier checksum doit être nommé exactement
`ArchLinuxARM-aarch64-latest.tar.gz.md5`. La confirmation `CONFIRM_ERASE` doit
correspondre exactement au disque cible. Ne choisissez jamais une partition
comme `/dev/sdX1` : le script attend le disque entier.

## 8. Activer le démarrage USB et démarrer

1. Sauvegarder les données, éteindre le Chromebook.
2. Maintenir **Échap + Actualiser (⟳)**, puis appuyer sur le bouton
   d'alimentation latéral.
3. À l'écran de récupération, appuyer sur **Ctrl + D**, puis confirmer.
   Cette opération efface les données locales et active le mode développeur.
4. Depuis le shell développeur ChromeOS, autoriser le démarrage USB :

   ```sh
   sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0
   ```

5. Insérer la clé, redémarrer et, à l'écran « OS verification is OFF »,
   appuyer sur **Ctrl + U**.

Le premier démarrage peut rester sans image si le pilote écran ou le DTS ne
correspond pas exactement à l'appareil. Prévoir un accès série ou un autre
moyen de diagnostic avant de considérer le portage prêt.

## 9. Installation interne (expérimental, eMMC uniquement)

**Non supporté sur les machines UFS** (`/dev/sda`) : le script refuse tout disque qui n'est pas
`/dev/mmcblk*`, ce qui est voulu (dual-boot UFS de l'auteur fait à la main : `notes/internal-dualboot-20261009.md`).

`install/flash-internal.sh` n'agrandit pas automatiquement les partitions. Il
attend que les partitions KERN-B (p4) et ROOT-C (p7) existent déjà et formate
ROOT-C. Il sauvegarde KERN-A/KERN-B et leurs drapeaux dans
`/root/backup/asus-cm14-*`, puis écrit uniquement le nouveau noyau dans KERN-B.
Les partitions ChromeOS ROOT-A (p3) et ROOT-B (p5) ne sont pas modifiées.

**Ne lancez ce script que si vous comprenez la table GPT, avez une sauvegarde
externe complète et avez vérifié la taille de ROOT-C.** La restauration des
deux images noyau et de leurs drapeaux se fait avec :

```sh
sudo bash install/restore-chromeos.sh
```

Cette restauration ne rétablit pas le contenu de ROOT-C et ne remplace pas une
sauvegarde complète de ChromeOS. L'installation interne et le retour arrière
doivent encore être validés sur un appareil de test.

## 10. Dépannage

- **« No matching configuration »** : vérifier les `compatible` du FIT, la
  board Quigon réelle et la DTB choisie; ne pas mélanger MT8186 et MT8189.
- **Écran noir** : essayer le noyau ChromeOS pour récupérer; comparer le
  panneau, les ponts eDP/DP et les GPIO à la DTB stock avant de modifier le DTS.
- **Pas de Wi-Fi** : identifier le modèle exact avec les données ChromeOS,
  vérifier le pilote PCIe/SDIO et le firmware correspondant dans `linux-firmware`.
- **Pas de son** : relever la carte avec `aplay -l`, puis installer un profil
  UCM2 adapté au codec effectivement détecté. Le DTS audio actuel n'est pas une
  preuve de codec.
- **Boucle ou retour ChromeOS** : utiliser le mode développeur, examiner les
  priorités avec `cgpt show` et restaurer KERN-A/KERN-B depuis les sauvegardes.
- **Omarchy ne s'installe pas** : vérifier séparément la disponibilité des
  paquets ARM64; ne pas lancer les scripts Omarchy qui installent un noyau
  `linux-zen`, un microcode Intel ou un pilote NVIDIA.

## 11. Vérifications du dépôt

```sh
bash scripts/fix-perms.sh --git
bash scripts/fix-perms.sh --check
find install scripts port -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
git ls-files '*.fit' '*.dtb' '*.bin' '*.img' '*.tar*' '*.zip' '*.xz'
```

`git ls-files` ne doit pas lister d'artefacts binaires. Avant un commit, vérifier
également l'absence de clés, secrets Wi-Fi, identifiants matériels et chemins
personnels.

## Crédits

Ce dépôt reprend des travaux antérieurs de `zoan37`. Les changements de ce
dépôt ciblent l'ASUS CM14 et Corsola/Quigon.
