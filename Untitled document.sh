patch-shimboot-sd.sh


#!/usr/bin/env bash
set -e


IMAGE="${1:-shimboot.img}"
MNT="/mnt/shimboot"


if [[ $EUID -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi


if [[ ! -f "$IMAGE" ]]; then
    echo "Image not found: $IMAGE"
    exit 1
fi


mkdir -p "$MNT"


echo "[*] Creating loop device"
LOOP=$(losetup --show -Pf "$IMAGE")
echo "[*] Loop device: $LOOP"


sleep 1
lsblk "$LOOP"


BOOT_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"


if [[ ! -b "$ROOT_PART" ]]; then
    ROOT_PART="${LOOP}p4"
fi


if [[ ! -b "$ROOT_PART" ]]; then
    echo "Could not determine root partition"
    losetup -d "$LOOP"
    exit 1
fi


ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")


if [[ -z "$ROOT_UUID" ]]; then
    echo "Could not determine root UUID"
    losetup -d "$LOOP"
    exit 1
fi


echo "[*] Root UUID: $ROOT_UUID"
echo "[*] Root PARTUUID: $ROOT_PARTUUID"


mount "$ROOT_PART" "$MNT"


mkdir -p "$MNT/bootpart"


if [[ -b "$BOOT_PART" ]]; then
    mount "$BOOT_PART" "$MNT/bootpart" || true
fi


BOOTCFG=""


for file in \
    "$MNT/boot/grub/grub.cfg" \
    "$MNT/boot/extlinux/extlinux.conf" \
    "$MNT/boot/syslinux/syslinux.cfg" \
    "$MNT/bootpart/grub/grub.cfg" \
    "$MNT/bootpart/extlinux/extlinux.conf" \
    "$MNT/bootpart/syslinux/syslinux.cfg"
do
    if [[ -f "$file" ]]; then
        BOOTCFG="$file"
        break
    fi
done


if [[ -z "$BOOTCFG" ]]; then
    echo "No bootloader config found"
else
    echo "[*] Patching boot config: $BOOTCFG"


    cp "$BOOTCFG" "$BOOTCFG.bak"


    sed -i -E \
        's#root=/dev/sd[a-z][0-9]+#root=PARTUUID='"$ROOT_PARTUUID"'#g' \
        "$BOOTCFG"


    sed -i -E \
        's#root=/dev/mmcblk[0-9]+p[0-9]+#root=PARTUUID='"$ROOT_PARTUUID"'#g' \
        "$BOOTCFG"


    if ! grep -q "rootwait" "$BOOTCFG"; then
        sed -i 's# rw# rw rootwait rootdelay=5#g' "$BOOTCFG"
    fi
fi


FSTAB="$MNT/etc/fstab"


if [[ -f "$FSTAB" ]]; then
    echo "[*] Patching fstab"


    cp "$FSTAB" "$FSTAB.bak"


    sed -i -E \
        's#^/dev/[a-zA-Z0-9/]+#UUID='"$ROOT_UUID"'#g' \
        "$FSTAB"
fi


MODULES="$MNT/etc/initramfs-tools/modules"


if [[ -f "$MODULES" ]]; then
    echo "[*] Adding MMC drivers"


    grep -qxF 'mmc_core' "$MODULES" || echo 'mmc_core' >> "$MODULES"
    grep -qxF 'sdhci' "$MODULES" || echo 'sdhci' >> "$MODULES"
    grep -qxF 'sdhci_pci' "$MODULES" || echo 'sdhci_pci' >> "$MODULES"
    grep -qxF 'cqhci' "$MODULES" || echo 'cqhci' >> "$MODULES"
fi


if [[ -d "$MNT/usr" ]]; then
    echo "[*] Mounting pseudo filesystems"


    mount --bind /dev "$MNT/dev"
    mount --bind /proc "$MNT/proc"
    mount --bind /sys "$MNT/sys"


    echo "[*] Rebuilding initramfs"


    chroot "$MNT" update-initramfs -u || true


    umount "$MNT/dev" || true
    umount "$MNT/proc" || true
    umount "$MNT/sys" || true
fi


sync


umount "$MNT/bootpart" 2>/dev/null || true
umount "$MNT"


losetup -d "$LOOP"


echo


echo "Patch complete"
echo "Image now supports delayed SD card initialization"