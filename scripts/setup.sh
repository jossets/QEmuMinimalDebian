#!/bin/bash
# Exécuté en root DANS la VM pendant la construction.
# Usage: setup.sh <autologin_user|-> <hostname> [paquets...]
set -eu
AUTOLOGIN_USER="${1:--}"; HOSTNAME_NEW="${2:-debian-min}"; shift 2 || true
EXTRA_PKGS="$*"
export DEBIAN_FRONTEND=noninteractive

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

echo "### [1/9] Paquets: purge de l'inutile (seulement ce qui est installé)"
PURGE=""
for p in unattended-upgrades rsyslog man-db manpages bluez modemmanager network-manager \
         avahi-daemon cups packagekit udisks2 accountsservice rpcbind nfs-common \
         exim4-base exim4-daemon-light apt-listchanges reportbug popularity-contest \
         qemu-guest-agent chrony ntpsec e2scrub-all laptop-detect installation-report os-prober; do
  pkg_installed "$p" && PURGE="$PURGE $p"
done
[ -n "$PURGE" ] && apt-get purge -y --auto-remove $PURGE || true
if [ -n "$EXTRA_PKGS" ]; then
  apt-get update
  apt-get install -y --no-install-recommends $EXTRA_PKGS
fi

# Groupes supplémentaires: USER_GROUPS="user:grp1,grp2;user2:grp" (ignore les groupes absents)
IFS=';' read -ra UG <<< "${USER_GROUPS:-}"
for entry in "${UG[@]}"; do
  [ -z "$entry" ] && continue
  u="${entry%%:*}"; IFS=',' read -ra GS <<< "${entry#*:}"
  for g in "${GS[@]}"; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$u" || echo "(groupe $g absent, ignoré)"
  done
done

# Docker: démarrage à la demande (socket activation) pour ne pas ralentir le boot
if unit_exists docker.socket; then
  systemctl disable docker.service containerd.service >/dev/null 2>&1 || true
  systemctl enable docker.socket >/dev/null 2>&1 || true
fi

# sshd: port forwarding autorisé (-L / -R / -D)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-forwarding.conf <<'EON'
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
GatewayPorts clientspecified
PermitTunnel yes
EON

echo "### [2/9] Hostname"
echo "$HOSTNAME_NEW" > /etc/hostname
sed -i "s/^127.0.1.1.*/127.0.1.1 $HOSTNAME_NEW/" /etc/hosts || true

echo "### [3/9] Services & timers inutiles -> masqués (si présents)"
for u in NetworkManager NetworkManager-wait-online systemd-networkd-wait-online \
         ModemManager bluetooth cups avahi-daemon packagekit udisks2 accounts-daemon \
         rpcbind nfs-client.target exim4 rsyslog man-db.timer apt-daily.timer \
         apt-daily-upgrade.timer fstrim.timer e2scrub_all.timer e2scrub_reap.service \
         dpkg-db-backup.timer logrotate.timer motd-news.timer systemd-timesyncd \
         grub-common.service uuidd.socket uuidd.service systemd-binfmt.service \
         proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount \
         systemd-pstore.service console-setup.service keyboard-setup.service ; do
  unit_exists "$u" && systemctl mask "$u" >/dev/null 2>&1 || true
done

echo "### [4/9] Réseau: systemd-networkd, DHCP, sans attente"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-dhcp.network <<'EON'
[Match]
Name=en* eth*
[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no
[DHCPv4]
UseDomains=false
EON
# les fichiers de config générés par cloud-init/netplan/ifupdown ne doivent pas entrer en conflit
rm -f /etc/systemd/network/*cloud-init* /etc/network/interfaces.d/* /etc/netplan/*.yaml 2>/dev/null || true
systemctl enable systemd-networkd.service >/dev/null 2>&1 || true
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

echo "### [5/9] systemd: timeouts courts, journald en RAM"
mkdir -p /etc/systemd/system.conf.d /etc/systemd/journald.conf.d /etc/systemd/logind.conf.d
cat > /etc/systemd/system.conf.d/fast-boot.conf <<'EON'
[Manager]
DefaultTimeoutStartSec=5s
DefaultTimeoutStopSec=2s
LogLevel=warning
ShowStatus=no
EON
cat > /etc/systemd/journald.conf.d/fast-boot.conf <<'EON'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
ForwardToSyslog=no
EON
cat > /etc/systemd/logind.conf.d/fast-boot.conf <<'EON'
[Login]
NAutoVTs=1
EON

echo "### [6/9] sshd en socket-activation (démarre à la 1re connexion)"
if unit_exists ssh.socket; then
  systemctl disable ssh.service >/dev/null 2>&1 || true
  systemctl enable ssh.socket   >/dev/null 2>&1 || true
fi

echo "### [7/9] Autologin console"
if [ "$AUTOLOGIN_USER" != "-" ]; then
  mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EON
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear --keep-baud 115200,57600,38400,9600 %I \$TERM
EON
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EON
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear %I \$TERM
EON
fi

echo "### [8/9] fstab noatime, GRUB sans délai, initramfs minimal mais portable"
sed -i -E 's|^(\S+\s+/\s+ext4\s+)(\S+)|\1defaults,noatime|' /etc/fstab
sed -i '/\sswap\s/d' /etc/fstab
sed -i -E '/^(GRUB_TIMEOUT|GRUB_TIMEOUT_STYLE|GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX|GRUB_DISABLE_OS_PROBER|GRUB_RECORDFAIL_TIMEOUT)=/d' /etc/default/grub
cat >> /etc/default/grub <<'EON'
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISABLE_OS_PROBER=true
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 console=tty0 console=ttyS0,115200n8 mitigations=off nowatchdog noresume audit=0 lsm=lockdown,capability,landlock,yama ipv6.disable=1 systemd.show_status=0"
GRUB_CMDLINE_LINUX=""
EON
rm -f /etc/default/grub.d/*cloud* 2>/dev/null || true
# initramfs: modules de la machine de build + pilotes QEMU/virtio nécessaires aux autres configs
cat > /etc/initramfs-tools/conf.d/fast-boot <<'EON'
MODULES=dep
COMPRESS=zstd
EON
cat >> /etc/initramfs-tools/modules <<'EON'
virtio_pci
virtio_blk
virtio_scsi
virtio_net
virtio_console
ext4
sd_mod
ahci
ata_piix
EON
update-initramfs -u -k all
update-grub

echo "### [9/9] Purge cloud-init, nettoyage"
if pkg_installed cloud-init; then
  apt-get purge -y --auto-remove cloud-init cloud-guest-utils cloud-initramfs-growroot 2>/dev/null \
    || apt-get purge -y --auto-remove cloud-init
fi
rm -rf /etc/cloud /var/lib/cloud /var/log/cloud-init* 2>/dev/null || true
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
       /var/log/*.log /var/log/journal 2>/dev/null || true
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
sync
echo "### setup terminé"
