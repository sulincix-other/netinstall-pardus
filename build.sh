#!/bin/bash
set -ex
###################### create base system ########################
mkdir -p work/chroot
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

###################### install packages ########################
chroot work/chroot apt install -yq --no-install-recommends \
     parted debootstrap busybox e2fsprogs linux-image-amd64 \
     kmod nano

###################### insert init ########################
install ./init.sh work/chroot/init

###################### cleanup ########################

chroot work/chroot apt clean
find work/chroot/var/log -type f -exec rm -f {} \;
