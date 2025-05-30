#!/bin/bash
set -ex
###################### create base system ########################
mkdir -p work/chroot work/iso
ln -s sid /usr/share/debootstrap/scripts/yirmiuc-deb || true
debootstrap --variant minbase --include "usr-is-merged usrmerge" yirmiuc-deb work/chroot https://depo.pardus.org.tr/pardus
cat > work/chroot/etc/apt/sources.list <<EOF
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

chroot work/chroot apt update --allow-insecure-repositories
chroot work/chroot apt install pardus-archive-keyring --allow-unauthenticated -yq
chroot work/chroot apt update
chroot work/chroot apt full-upgrade -yq

cat > work/chroot/etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

###################### install packages ########################
chroot work/chroot apt install -yq --no-install-recommends \
     parted debootstrap busybox e2fsprogs linux-image-amd64 \
     kmod nano dropbear dosfstools

###################### insert init ########################
install ./init.sh work/chroot/init

###################### extract vmlinuz ########################
mv work/chroot/boot/vmlinuz-* work/iso/linux
rm -rf work/chroot/boot work/chroot/initrd.img* work/chroot/vmlinuz*

###################### cleanup ########################
# soft clean
chroot work/chroot apt clean
find work/chroot/var/log -type f -exec rm -f {} \;
# hard clean
rm -rf work/chroot/usr/share/man
rm -rf work/chroot/usr/share/i18n
rm -rf work/chroot/usr/share/doc
rm -rf work/chroot/usr/share/help
rm -rf work/chroot/usr/share/locale
rm -rf  work/chroot/lib/modules/*/kernel/drivers/media
rm -rf  work/chroot/lib/modules/*/kernel/drivers/gpu
rm -rf  work/chroot/lib/modules/*/kernel/drivers/net/wireless
rm -rf  work/chroot/lib/modules/*/kernel/drivers/video
rm -rf  work/chroot/lib/modules/*/kernel/drivers/bluetooth
rm -rf  work/chroot/lib/modules/*/kernel/sound

###################### create initramfs ########################
cd work/chroot
find . | cpio -o -H newc | gzip -9 > ../iso/initrd.img

###################### create iso image ########################
cd ../iso
mkdir -p boot/grub
cat > boot/grub/grub.cfg <<EOF
insmod all_video
terminal_output console
terminal_input console
menuentry "Pardus Network Install (Automated)" --class linux {
    linux /linux quiet
    initrd /initrd.img
}
EOF
# create iso
cd ../
grub-mkrescue iso -o pardus-netinstall.iso --fonts="" --install-modules="linux normal fat all_video" --compress=xz --locales=""

###################### create pxe image ########################
mkdir -p pxe/boot/grub/
grub-mknetdir --net-directory=./pxe
install iso/linux ./pxe/linux
install iso/initrd.img ./pxe/initrd.img
install iso/boot/grub/grub.cfg pxe/boot/grub/grub.cfg
zip -r pardus-pxe.zip pxe
