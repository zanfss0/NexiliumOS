#!/usr/bin/env bash
set -euo pipefail

ROOTFS="/opt/nexilium-rootfs"
ISO_ROOT="/opt/nexilium-iso"
OUTPUT="$(pwd)/output"
ISO_NAME="NexiliumOS.iso"

# Limpa mounts antigos se existirem
for mnt in dev/pts dev sys proc; do
    mountpoint -q "$ROOTFS/$mnt" 2>/dev/null && sudo umount -lf "$ROOTFS/$mnt" || true
done

echo "==> Bootstrap Debian Trixie..."
sudo debootstrap --arch=amd64 trixie "$ROOTFS" http://deb.debian.org/debian

echo "==> Copiando configs..."
sudo cp config/sources.list      "$ROOTFS/etc/apt/sources.list"
sudo cp config/os-release        "$ROOTFS/etc/os-release"
sudo cp config/packages.list     "$ROOTFS/tmp/packages.list"
sudo cp scripts/chroot-setup.sh  "$ROOTFS/tmp/chroot-setup.sh"
sudo chmod +x "$ROOTFS/tmp/chroot-setup.sh"

echo "==> Montando filesystems virtuais..."
sudo mount --bind /proc    "$ROOTFS/proc"
sudo mount --bind /sys     "$ROOTFS/sys"
sudo mount --bind /dev     "$ROOTFS/dev"
sudo mount --bind /dev/pts "$ROOTFS/dev/pts"

echo "==> Rodando setup no chroot..."
sudo chroot "$ROOTFS" /tmp/chroot-setup.sh

echo "==> Desmontando..."
sudo umount "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc"

echo "==> Gerando squashfs..."
mkdir -p "$OUTPUT"
sudo mksquashfs "$ROOTFS" "$OUTPUT/filesystem.squashfs" -comp xz -noappend 2>&1 | grep -v "Unrecognised xattr" || true

echo "==> Montando estrutura do ISO..."
sudo rm -rf "$ISO_ROOT"
sudo mkdir -p "$ISO_ROOT"/{live,boot/grub}

sudo cp "$OUTPUT/filesystem.squashfs" "$ISO_ROOT/live/"
sudo cp "$ROOTFS/boot"/vmlinuz-*      "$ISO_ROOT/boot/vmlinuz"
sudo cp "$ROOTFS/boot"/initrd.img-*   "$ISO_ROOT/boot/initrd.img"

sudo tee "$ISO_ROOT/boot/grub/grub.cfg" > /dev/null << 'GRUB'
set default=0
set timeout=5

menuentry "NexiliumOS" {
    linux  /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "NexiliumOS (modo seguro)" {
    linux  /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Gerando ISO bootável..."
sudo grub-mkrescue -o "$OUTPUT/$ISO_NAME" "$ISO_ROOT" -- -volid "NEXILIUMOS"

echo "==> ISO gerado:"
ls -lh "$OUTPUT/$ISO_NAME"
echo "==> Build concluído!"
