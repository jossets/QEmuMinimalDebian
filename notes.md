J'ai écrit le pipeline de construction et lancé un premier build en arrière-plan. Il n'est pas terminé, donc rien n'est encore validé. Le boot sous TCG prend plusieurs minutes, et je vous préviens à la fin.

Fichiers créés

scripts/build.py orchestre le build sous Windows avec Python, PyYAML et le QEMU de C:\Tools\qemu. Il suit votre pipeline du README :
Il télécharge l'image cloud Debian 13 et vérifie son SHA512 (cache dans cache/).
Il génère le cloud-init (utilisateur, clé SSH, sudo). Je le sers par un petit serveur HTTP local via -smbios ds=nocloud;s=http://10.0.2.2:8000/, donc aucun outil pour fabriquer un ISO n'est nécessaire.
Il démarre la VM en TCG avec SSH redirigé sur le port 2222.
Il envoie setup.sh, l'exécute en root, éteint la VM puis compresse le disque en zstd vers VMs/qcow2/debian-min.qcow2.
scripts/setup.sh s'exécute dans la VM et applique vos recommandations du README. Il ne purge ni ne masque que ce qui est présent, sans rien installer pour le désactiver.
Services et paquets : il purge cloud-init et les paquets inutiles, et masque les services et timers de votre liste.
Réseau : systemd-networkd en DHCP, sans attente du réseau.
Réglages systemd : timeouts courts et journald en RAM.
Disque : noatime, pas de swap.
Démarrage : GRUB sans délai, cmdline quiet, mitigations=off, ipv6.disable=1. L'initramfs est en MODULES=dep avec zstd, et je force les modules virtio, ext4, ahci et ata_piix pour garder l'image portable.
Console : autologin de yolo sur la console série, pour arriver directement sur un shell.
Finition : sshd en socket-activation et mise à zéro de l'espace libre pour mieux compresser.
.gitignore exclut VMs/creds/id_rsa, cache/, work/ et les .qcow2.
À savoir

J'ai réécrit VMs/vm_debian_min.yml en vrai mapping YAML. Vos clés (repo, base, img, users…) sont gardées, avec quelques ajouts : hostname, disk_size, build_memory, build_cpus, autologin.
J'ai retiré repo_debian de conf.yml. L'URL est maintenant dans base_url du fichier de la VM.
Les clés SSH de l'hôte sont gardées dans l'image pour éviter une génération RSA lente au premier boot. Toutes les copies distribuées auront donc les mêmes clés d'hôte. Pour des ateliers, c'est acceptable.
Ce build ne valide que le provisioning. Le gain de temps de boot reste à mesurer avec systemd-analyze une fois l'image produite.
Si le build échoue, work/console.log contient la console série de la VM.
Prochaine étape : si le build réussit, je mesure le boot avec vm_start.ps1 et systemd-analyze pour itérer sur les gains.