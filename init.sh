#!/bin/bash
if [ $$ -eq 1 ] ; then
    # kill init guard
    bash -ex /init
    echo "init dead!"
    PS1=">>> " bash
    exec sleep inf
fi
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
dropbear -R -E 2>/dev/null || true
sync && sleep 1

############### detect disk ###############
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

############### load config ###############
export PARTITION=true
export DEBOOTSTRAP=true
export CONFIGURE=true
export INSTALL_KERNEL=true
export INSTALL_GRUB=true
export INSTALL_PACKAGES="pardus-xfce-desktop"
export USER_NAME="pardus"
export USER_REALNAME="Pardus"
export USER_PASSWORD="pardus"
export REPO="https://depo.pardus.org.tr/pardus"
export REPO_SEC="http://depo.pardus.org.tr/guvenlik"

for item in $(cat /proc/cmdline | tr " " "\n" | grep "=") ; do
    name=${item/=*/}
    name=${name/./_}
    value=${item/*=/}
    export "${name^^}"="$value"
done

############### run init ###############
if [ "$INIT" != "" ] ; then
    wget -O /tmp/init.sh "$INIT"
    bash -ex /tmp/init.sh
fi


# detect disk prefix
if echo ${DISK} | grep nvme ; then
    DISKX=${DISK}p
else
    DISKX=${DISK}
fi

############### part and format disk ###############
mkdir -p /target
if [ "$PARTITION" == "false" ] ; then
    echo "paratitioning disabled"
elif [ -d /sys/firmware/efi ] ; then
    parted -s /dev/"${DISK}" mktable gpt
    parted -s /dev/"${DISK}" mkpart primary fat32 1 "500MB"
    parted -s /dev/"${DISK}" mkpart primary fat32 500MB "100%"
    sync && sleep 1
    yes | mkfs.vfat /dev/${DISKX}1
    yes | mkfs.ext4  /dev/${DISKX}2
    mount /dev/${DISKX}2 /target
    mkdir -p /target/boot/efi
    mount /dev/${DISKX}2 /target/boot/efi
    uuid_efi=$(blkid  /dev/${DISKX}1 | sed "s/ /\n/g" | grep "^UUID")
    uuid_rootfs=$(blkid  /dev/${DISKX}2 | sed "s/ /\n/g" | grep "^UUID")
    echo "${uuid_efi} /boot/efi vfat defaults,rw 0 0" > /tmp/fstab
    echo "${uuid_rootfs} / ext4 defaults,rw 0 1" >> /tmp/fstab
else
    parted -s /dev/"${DISK}" mktable msdos
    parted -s /dev/"${DISK}" mkpart primary fat32 1 "100%"
    sync && sleep 1
    yes | mkfs.ext4  /dev/${DISKX}1
    mount /dev/${DISKX}1 /target
    uuid_rootfs=$(blkid  /dev/${DISKX}1 | sed "s/ /\n/g" | grep "^UUID")
    echo "${uuid_rootfs} / ext4 defaults,rw 0 1" >> /tmp/fstab
fi
sync && sleep 1

############### install base system ###############
debootstrap --include "usr-is-merged usrmerge" yirmiuc-deb /target "$REPO"
cat > /target/etc/apt/sources.list <<EOF
### The Official Pardus Package Repositories ###

## Pardus
deb ${REPO} yirmiuc main contrib non-free non-free-firmware
# deb-src ${REPO} yirmiuc main contrib non-free non-free-firmware

## Pardus Deb
deb ${REPO} yirmiuc-deb main contrib non-free non-free-firmware
# deb-src ${REPO} yirmiuc-deb main contrib non-free non-free-firmware

## Pardus Security Deb
deb ${REPO_SEC} yirmiuc-deb main contrib non-free non-free-firmware
# deb-src ${REPO_SEC} yirmiuc-deb main contrib non-free non-free-firmware

EOF

chroot /target apt update --allow-insecure-repositories
chroot /target apt install pardus-archive-keyring --allow-unauthenticated -yq
chroot /target apt update
chroot /target apt full-upgrade -yq
    sync && sleep 1

############### install packages ###############
for dir in dev sys proc ; do
    mount --bind /$dir /target/$dir
done
# kernel
if [ "${INSTALL_KERNEL}" != "false" ] ; then
    chroot /target apt install -yq linux-image-amd64
    sync && sleep 1
fi

############### install grub ###############
if [ -f /tmp/fstab ] ; then
    mv /tmp/fstab /target/etc/fstab
fi

if [ "${INSTALL_GRUB}" != "false" ] ; then
    if [ -d /sys/firmware/efi ] ; then
        chroot /target apt install -yq grub-efi
        chroot /target mount -t efivarfs efivarfs /sys/firmware/efi/efivars
        chroot /target grub-install /dev/${DISK} --target="x86_64-efi"
    else
        chroot /target apt install -yq grub-pc
        chroot /target grub-install /dev/${DISK} --target="i386-pc"
    fi
    chroot /target grub-mkconfig -o /boot/grub/grub.cfg
    sync && sleep 1
fi
############### configure ###############
if [ "$CONFIGURE" != "false" ] ; then
    # X11 keyboard
    mkdir -p /target/etc/X11/xorg.conf.d/
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
fi
############### install additional packages ###############
# desktop
chroot /target apt install -yq ${INSTALL_PACKAGES}
sync && sleep 1

############### create user ###############
chroot /target useradd -m ${USER_NAME} -c "${USER_REALNAME}" -G cdrom,floppy,sudo,audio,dip,video,plugdev,netdev,bluetooth,scanner,lpadmin -s /bin/bash -p $(openssl passwd -6 ${USER_PASSWORD})
sync && sleep 1

############### reboot ###############
busybox reboot -f
echo "init done"
