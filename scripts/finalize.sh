#!/bin/bash
# Dernière étape du build, après tout le provisioning (docker load, fichiers...):
# met à zéro l'espace libre pour que qemu-img convert -c produise un qcow2 compact.
set -u
apt-get clean
rm -rf /tmp/* 2>/dev/null || true
sync
dd if=/dev/zero of=/zero.fill bs=1M 2>/dev/null || true
sync; rm -f /zero.fill; sync
echo "### finalize terminé"
