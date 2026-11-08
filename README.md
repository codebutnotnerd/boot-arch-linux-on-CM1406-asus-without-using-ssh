# Arch Linux ARM sur ASUS Chromebook CM1406 — carte Skywalker « Tarkin » (MT8189)

Démarrage **depuis une clé USB uniquement**. Rien n'est écrit sur le disque interne : ChromeOS reste en place.

## Statut honnête

| Niveau | Contenu |
|---|---|
| **Vérifié sur ta machine** | Carte `google,tarkin`, SoC MT8189, eMMC, noyau stock 6.6, slot actif KERN-B (p4), noyau repackable et signable avec `futility` (rapport de pré-vérification), outils présents, réseau joignable. Détails : `notes/tarkin-findings.md`. |
| **Simulé (faux disques, faux `cgpt`/`futility`)** | Le déroulement complet de `install/install-usb.sh` : garde-fous, choix du slot, cmdline, partitions, extraction, Wi-Fi, SSH, permissions, services. |
| **Jamais testé** | Le démarrage réel depuis la clé, le chroot ARM réel, le Wi-Fi MT7925, l'écran, l'audio, le touchpad, le GPU. |

Ce paquet ne garantit donc **pas** que ça démarre. Le premier essai réel est le vrai test.

## À savoir avant de commencer

- **Écran noir attendu.** Le noyau ChromeOS n'a pas de console graphique. L'accès se fait **par SSH**, depuis un autre appareil du même réseau, avec ta clé publique.
- **Pas de bureau Hyprland.** ChromeOS n'a pas `git` : le clone d'Omarchy est ignoré. Tu obtiens un Arch Linux ARM de base avec SSH.
- **Wi-Fi** : WPA2-PSK uniquement. Pour un réseau WPA3 seul, d'entreprise ou masqué, utilise un partage de connexion de téléphone en WPA2 pour ce premier test.
- **Matériel Obiwan, pas Tarkin.** L'audio (UCM RT5682S/RT1019P, ta carte est `mt8189_rt5650`), le filtre palm du touchpad (cherche `Elan Touchpad`, le tien est `04F3:31C6`) et le reste de `port/quigon/` viennent d'une autre variante. Ils sont installés mais ne marcheront probablement pas.
- Les scripts qui écrivent sur le disque interne sont **désactivés** : `install/flash-internal.sh.DISABLED` et `install/restore-chromeos.sh.DISABLED`.

## Procédure

Prérequis : ChromeOS en mode développeur, un autre appareil avec une clé SSH, une clé USB **vide ou sans importance** (tout son contenu sera effacé).

1. **Clé SSH.** Sur l'autre appareil : `ssh-keygen -t ed25519`, puis affiche le `.pub`. Sur le Chromebook (shell du navigateur, `Ctrl+Alt+T` puis `shell`) :
   ```sh
   echo 'ssh-ed25519 AAAA… ta_clé_publique' > /var/tmp/key.pub
   ```
2. **Dépôt.** Décompresse ce zip dans `/var/tmp` (`cd /var/tmp && bsdtar -xf ~/MyFiles/Downloads/asus-cm14-tarkin-ready.zip`), puis `cd /var/tmp/asus-cm14-chromebook-omarchy`.
3. **Pré-vérification (lecture seule).** Dans VT2 (`Ctrl+Alt+⟳`, utilisateur `chronos`) :
   ```sh
   sudo bash /var/tmp/asus-cm14-chromebook-omarchy/scripts/preflight-tarkin.sh
   ```
   Lis ensuite `/var/tmp/pf/report.txt`. Si une ligne affiche `MANQUANT`, `ABSENT` ou `ECHEC`, ne continue pas.
4. **Archive Arch.**
   ```sh
   cd /var/tmp
   curl -fLO https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
   curl -fLO https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
   md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5
   ```
5. **Identifier la clé.** Branche-la, puis `lsblk -o NAME,SIZE,RM,TRAN`. La clé a `RM=1` et `TRAN=usb`. Ton disque interne est `/dev/mmcblk0` : **ne jamais** le choisir.
6. **Installer** (VT2, `sdX` = ta clé, `NomWifi` = ton réseau ; le mot de passe est demandé en saisie masquée) :
   ```sh
   cd /var/tmp/asus-cm14-chromebook-omarchy
   sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh \
     --alarm /var/tmp/ArchLinuxARM-aarch64-latest.tar.gz \
     --wifi-ssid "NomWifi" --pubkey "$(cat /var/tmp/key.pub)" /dev/sdX
   ```
7. **Démarrer.** Éteins, laisse la clé branchée, rallume et appuie sur `Ctrl+U` sur l'écran « OS verification is OFF » (pas de bip). L'écran restera noir.
8. **Se connecter.** Après environ une minute, cherche l'appareil `asus-cm14` dans la liste de ton routeur, puis `ssh alarm@<ip>`.

Si rien n'apparaît après 2 à 3 minutes, éteins avec le bouton latéral : ChromeOS redémarre depuis le disque interne. Dis-moi alors ce que l'écran a fait (menu de vérification, bip, boucle, noir sans fin).

## Retour arrière

- Le disque interne n'est jamais modifié. Sans la clé, la machine démarre ChromeOS (`Ctrl+D` sur l'écran de développeur).
- L'installateur règle deux flags du firmware (`dev_boot_usb=1`, `dev_boot_signed_only=0`). Pour les annuler : `sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.
- Le dossier temporaire `/var/tmp/pf` créé par la pré-vérification peut être supprimé sans risque.

## Ce qui a changé par rapport au dépôt d'origine

| Fichier | Changement |
|---|---|
| `install/install-usb.sh` | Slot actif détecté (p4 chez toi, au lieu de p2) ; `lsm=` ajouté à la cmdline (LoadPin est actif) ; fonctionne sans `python3` ; installe `wpa_supplicant` par chroot ; exige `--pubkey` et un réseau Wi-Fi ; permissions durcies ; plus de commentaires. |
| `scripts/preflight-tarkin.sh` | Nouveau : tests en lecture seule avant tout effacement. |
| `scripts/identify-device.sh` | Slot actif détecté ; HWID, numéro de série et UUID retirés des sorties. |
| `scripts/build-usb.sh` | Slot actif détecté (l'ancien `…2` donnait `/dev/mmcblk02` sur eMMC). Reste dépendant d'un « bridge » LAN : préfère `install-usb.sh`. |
| `port/quigon/root/usr/share/alsa/ucm2/conf.d/` | Entrées converties en liens symboliques (elles étaient des fichiers texte). |
| `install/flash-internal.sh`, `restore-chromeos.sh` | Désactivés (`.DISABLED`). |
| `README.md` | Remplacé. L'ancien est dans `notes/README-obiwan-original.md`. |

## Chemin B : DTS Tarkin (non fait)

Aucun `mt8189-tarkin.dts` n'est fourni : il faudrait porter à la main les nœuds du DT ChromeOS (6.6) vers le mainline, et rien ne le prouve réalisable avec ce dépôt. Les éléments déjà établis (SKU 4101, nœuds vus, noms des overlays Tarkin du FIT stock) sont dans `notes/tarkin-findings.md`.

## Règles de sécurité de ce paquet

- Tests sur clé USB uniquement (`Ctrl+U`), jamais sur le disque interne.
- L'installateur refuse un disque non amovible, non USB, le disque racine ChromeOS et tout `mmcblk*`, et exige `CONFIRM_ERASE=<disque exact>`.
- Ne publie pas tes sorties brutes : HWID, UUID de partitions et mots de passe sont des identifiants.
