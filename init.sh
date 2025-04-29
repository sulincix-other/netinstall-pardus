#!/bin/bash
source /etc/profile
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
set -ex
exec <>/dev/console
agetty -L 115200 -a root tty2 &
############### mount sysfs ###############
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
############### udevd ###############
/lib/systemd/systemd-udevd --daemon --debug &> /var/log/udevd.log
udevadm trigger -c add &> /var/log/udevd-trigger.log
udevadm settle
sync && sleep 1

############### networking ###############
mkdir -p /usr/share/udhcpc/
cat > /usr/share/udhcpc/default.script <<EOF
busybox ip addr add \$ip/\$mask dev \$interface

if [ "\$router" ]; then
  busybox ip route add default via \$router dev \$interface
fi
EOF
chmod 755 /usr/share/udhcpc/default.script
for dev in $(ls /sys/class/net/ | grep -v lo) ; do
    busybox ip link set up $dev || true
    busybox udhcpc -i $dev -s /usr/share/udhcpc/default.script || true
done
echo "nameserver 1.1.1.1" > /etc/hosts
echo "nameserver 8.8.8.8" >> /etc/hosts
sync && sleep 1

############### partitioning ###############
# detect primary disk
DISK=""
for d in $(ls /sys/block | grep -v "^dm" | grep -v "^fd"); do
    if echo $d | grep loop >/dev/null; then
        continue
    fi
    if [[ "0" == "$(cat /sys/block/$d/removable)" ]] && [[ "$(realpath /sys/block/$d | grep usb)" == "" ]] ; then
        DISK="$d"
        break
    fi
done

# detect disk prefix
if echo ${DISK} | grep nvme ; then
    DISKX=${DISK}p
else
    DISKX=${DISK}
fi

export DISK
export DISKX

if grep "^init=" /proc/cmdline >/dev/null ; then
    init=$(cat /proc/cmdline | tr " " "\n"  | grep "^init" | sed "s/^init=//g")
    wget -O /tmp/init.sh || bash
    bash -ex /tmp/init.sh
fi

mkdir -p /target
if [ -d /sys/firmware/efi ] ; then
    parted -s /dev/"${DISK}" mktable gpt || bash
    parted -s /dev/"${DISK}" mkpart primary fat32 1 "500MB" || bash
    parted -s /dev/"${DISK}" mkpart primary fat32 500MB "100%" || bash
    sync && sleep 1
    yes | mkfs.vfat /dev/${DISKX}1 || bash
    yes | mkfs.ext4  /dev/${DISKX}2 || bash
    mount /dev/${DISKX}2 /target
    mkdir -p /target/boot/efi
    mount /dev/${DISKX}2 /target/boot/efi || bash
    uuid_efi=$(blkid  /dev/${DISKX}1 | sed "s/ /\n/g" | grep "^UUID")
    uuid_rootfs=$(blkid  /dev/${DISKX}2 | sed "s/ /\n/g" | grep "^UUID")
    echo "${uuid_efi} /boot/efi vfat defaults,rw 0 0" > /tmp/fstab
    echo "${uuid_rootfs} / ext4 defaults,rw 0 1" >> /tmp/fstab
else
    parted -s /dev/"${DISK}" mktable msdos || bash
    parted -s /dev/"${DISK}" mkpart primary fat32 1 "100%" || bash
    sync && sleep 1
    yes | mkfs.ext4  /dev/${DISKX}1 || bash
    mount /dev/${DISKX}1 /target || bash
    uuid_rootfs=$(blkid  /dev/${DISKX}1 | sed "s/ /\n/g" | grep "^UUID")
    echo "${uuid_rootfs} / ext4 defaults,rw 0 1" >> /tmp/fstab
fi
sync && sleep 1

############### install base system ###############
debootstrap --include "usr-is-merged usrmerge" yirmiuc-deb /target https://depo.pardus.org.tr/pardus || bash
cat > /target/etc/apt/sources.list <<EOF
### The Official Pardus Package Repositories ###

## Pardus
deb http://depo.pardus.org.tr/pardus yirmiuc main contrib non-free non-free-firmware
# deb-src http://depo.pardus.org.tr/pardus yirmiuc main contrib non-free non-free-firmware

## Pardus Deb
deb http://depo.pardus.org.tr/pardus yirmiuc-deb main contrib non-free non-free-firmware
# deb-src http://depo.pardus.org.tr/pardus yirmiuc-deb main contrib non-free non-free-firmware

## Pardus Security Deb
deb http://depo.pardus.org.tr/guvenlik yirmiuc-deb main contrib non-free non-free-firmware
# deb-src http://depo.pardus.org.tr/guvenlik yirmiuc-deb main contrib non-free non-free-firmware

EOF

chroot /target apt update --allow-insecure-repositories || bash
chroot /target apt install pardus-archive-keyring --allow-unauthenticated -yq || bash
chroot /target apt update || bash
chroot /target apt full-upgrade -yq || bash
sync && sleep 1

############### install packages ###############
for dir in dev sys proc ; do
    mount --bind /$dir /target/$dir
done
# kernel
chroot /target apt install -yq linux-image-amd64 || bash
# desktop
chroot /target apt install -yq pardus-xfce-desktop || bash
sync && sleep 1

############### install grub ###############
mv /tmp/fstab /target/etc/fstab
if [ -d /sys/firmware/efi ] ; then
    chroot /target apt install -yq grub-efi || bash
    chroot /target mount -t efivarfs efivarfs /sys/firmware/efi/efivars || bash
    chroot /target grub-install /dev/${DISK} --target="x86_64-efi" || bash
else
    chroot /target apt install -yq grub-pc || bash
    chroot /target grub-install /dev/${DISK} --target="i386-pc" || bash
fi
chroot /target grub-mkconfig -o /boot/grub/grub.cfg
sync && sleep 1

############### configure ###############
# X11 keyboard
cat > /target/etc/X11/xorg.conf.d/10-keyboard.conf << EOF
Section "InputClass"
Identifier "system-keyboard"
MatchIsKeyboard "on"
Option "XkbLayout" "tr"
Option "XkbModel" "pc105"
#Option "XkbVariant" "f"
EndSection
EOF

# Language
echo "tr_TR.UTF-8 UTF-8" > /target/etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /target/etc/locale.gen
echo "LANG=tr_TR.UTF-8" > /target/etc/default/locale
echo "LC_CTYPE=en_US.UTF-8" >> /target/etc/default/locale
echo "Europe/Istanbul" > /target/etc/timezone
chroot /target timedatectl set-timezone Europe/Istanbul || true
rm -f /target/etc/localtime  || true
ln -s ../usr/share/zoneinfo/Turkey /target/etc/localtime
chroot /target locale-gen || true

# Hosts file
echo "pardus" > /target/etc/hostname
echo "127.0.0.1 localhost" > /target/etc/hosts
echo "127.0.1.1 pardus" >> /target/etc/hosts
echo "" >> /target/etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /target/etc/hosts
echo "::1     localhost ip6-localhost ip6-loopback" >> /target/etc/hosts
echo "ff02::1 ip6-allnodes" >> /target/etc/hosts
echo "ff02::2 ip6-allrouters" >> /target/etc/hosts

chroot /target useradd -m pardus -c "Pardus" -G cdrom,floppy,sudo,audio,dip,video,plugdev,netdev,bluetooth,scanner,lpadmin -s /bin/bash -p $(openssl passwd -6 pardus) || bash

sync && sleep 1

############### reboot ###############

reboot -f
