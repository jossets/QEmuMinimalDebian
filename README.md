# QEmuMinimalDebian




Construction d'un VMs, qui puisse booter le plus rapidement possible sous QEmu sans acceleration matérielle.
Cette VM sera utilisée pour des ateliers sur les vieux PC.
La config kernel et système doit être la plus légère possible.

Tout ce qui ralentit le système doit pouvoir être désactivé:
- Réduire le travail effectué par le système au démarrage : services, détection matérielle, attente réseau, périphériques inutiles.
- Réduire le coût de l'émulation CPU : noyau, pilotes, initramfs et système de fichiers adaptés à la machine virtuelle.

- Debian stable, installation minimale.
- Architecture amd64.
- Pas d'environnement graphique.
- Pas de serveur d'impression.
- Pas de tâches système supplémentaires.
- Pas de logiciels recommandés automatiquement.

Objectif : obtenir un système qui arrive directement sur un shell.


## Env de génération 

Windows 11
WSL
C:\Tools\qemu


## Specs des VMs

Dans le répertoire VMS/
Fichier cm_{vm name}.yml



## # Pipeline:
1. Download cloud-init QCOW2 (cached)
2. Create NoCloud seed.iso (meta-data + user-data)
3. Boot VM in QEMU with port 2222 → guest 22
4. Wait for SSH, push & run setup.sh as root
5. Shutdown, compress, export to ~/build/output/


# Preco pour la VM 

## Désactiver en priorité
Service / composant	Raison
NetworkManager	Si configuration réseau statique via systemd-networkd
systemd-networkd-wait-online	Évite d'attendre la disponibilité complète du réseau
ModemManager	Détection des modems
bluetooth	Inutile en VM
cups	Impression
avahi-daemon	Découverte mDNS
packagekit	Gestion graphique des paquets
udisks2	Gestion dynamique des disques
accounts-daemon	Gestion des comptes pour environnements desktop
rpcbind	RPC/NFS, si inutilisé
nfs-client	Si aucun montage NFS
exim4	Si aucun serveur SMTP local
rsyslog	Si journald suffit
man-db.timer	Mise à jour de la base des manuels
apt-daily.timer	Vérification automatique des mises à jour
apt-daily-upgrade.timer	Installation automatique des mises à jour

Attention : certains services ne seront pas installés dans une Debian minimale. Il ne faut pas chercher à les installer pour les désactiver !


## Réduire les délais d'attente systemd
C'est potentiellement l'une des optimisations les plus intéressantes.

Créer /etc/systemd/system.conf.d/fast-boot.conf :

[Manager]
DefaultTimeoutStartSec=5s
DefaultTimeoutStopSec=2s
LogLevel=warning

## supprimer le délai GRUB :

Dans /etc/default/grub :
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden

Puis :
update-grub



## éviter de charger des pilotes inutiles.
Initramfs
Dans /etc/initramfs-tools/conf.d/fast-boot :
MODULES=dep
COMPRESS=zstd

Puis :
update-initramfs -u -k all


MODULES=dep demande à initramfs-tools de ne conserver que les modules nécessaires à la machine courante.

Attention : cett image est destinée à tourner sur plusieurs configurations QEMU, il faut conserver les pilotes nécessaires à toutes ces configurations. En particulier :
- virtio_pci
- virtio_blk
- virtio_scsi si tu utilises SCSI
- virtio_net
- virtio_console
- ext4 si ton root filesystem est en ext4
Ne réduis pas aveuglément l'initramfs à une machine précise, ce QCow2 doit être distribué.


## Réduire les opérations disque
Je recommande :
- ext4 ;
- pas de swap si la VM a une mémoire suffisante ;
- montage / avec noatime ;
- pas de partitionnement excessivement complexe ;
- pas de LVM si tu n'en as pas besoin ;
- pas de chiffrement LUKS ;
- pas de RAID logiciel.
Dans /etc/fstab, par exemple :
UUID=xxxx / ext4 defaults,noatime 0 1


Tu peux aussi désactiver le timer TRIM si ton stockage virtuel ne le nécessite pas :
systemctl disable --now fstrim.timer


## Optimisations spécifiques à QEMU sans KVM
C'est probablement le point le plus important dans ton cas.

Je recommande de privilégier les périphériques VirtIO plutôt que les périphériques matériels émulés classiques.
Composant	Choix recommandé
Machine	pc ou q35
Accélération	tcg
Disque	virtio-blk-pci
Réseau	virtio-net-pci
Console	virtio-serial
Stockage	QCow2 avec cache adapté
Firmware	BIOS SeaBIOS pour commencer
CPU	max à tester face à qemu64

Exemple de lancement :
qemu-system-x86_64 \
  -machine pc,accel=tcg \
  -cpu max \
  -smp 2 \
  -m 512M \
  -drive file=debian.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n1 \
  -device virtio-net-pci,netdev=n1 \
  -nographic


QEMU utilise TCG pour émuler le CPU lorsqu'aucun accélérateur matériel n'est disponible. Les périphériques VirtIO permettent d'éviter une partie du coût de l'émulation de périphériques matériels traditionnels.


## Mesurer réellement les gains
Avant et après optimisation :
systemd-analyze time
systemd-analyze blame
systemd-analyze critical-chain
systemd-analyze plot > /tmp/boot.svg


Attention : blame ne mesure pas correctement tous les délais d'attente et les services démarrés en parallèle. Il faut aussi regarder critical-chain.


## Configuration matérielle VM
Composant	Choix
OS	Debian 13 minimal (amd64)
Init	systemd
CPU	2 vCPU TCG
RAM	512 Mo au départ
Disque	QCow2, 2 à 4 Go
Contrôleur disque	VirtIO Block
Réseau	VirtIO Net
Filesystem	ext4
Swap	Aucun
Console	Serial + VGA facultative
Bootloader	GRUB BIOS
GUI	Aucun


## Choix des composants logiciels
Voici ce que je conserverais et supprimerais.
Composant	Décision
systemd	Conserver
systemd-udevd	Conserver
journald	Conserver
systemd-networkd	Conserver
systemd-resolved	Facultatif
OpenSSH server	Conserver
cron	Facultatif
rsyslog	Supprimer
NetworkManager	Supprimer
ModemManager	Supprimer
Bluetooth	Supprimer
Avahi	Supprimer
CUPS	Supprimer
PackageKit	Supprimer
cloud-init	Supprimer
man-db	Supprimer
unattended-upgrades	Supprimer
apt-daily	Désactiver
AppArmor	Conserver
udev	Conserver


## Profil — Debian Lab Fast
- Initramfs réduit avec MODULES=dep
- GRUB sans timeout
- Suppression des services inutiles
- Pas de swap
- Console série uniquement
- Pas d'attente réseau superflue