#!/bin/bash
# shimboot build script - sd card compatible image
# produces a .bin file that works on sd cards and usb drives
# usage: ./build_complete.sh <board_name> [options]

set -e

export DEBIAN_FRONTEND=noninteractive
export DPKG_DEBUG=developer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build_work"
SHIM_DIR="${WORK_DIR}/shim"
ROOTFS_DIR="${WORK_DIR}/rootfs"
BOOT_DIR="${WORK_DIR}/boot"
IMAGE_FILE="${SCRIPT_DIR}/shimboot_$(date +%Y%m%d_%H%M%S).bin"
LOOP_DEVICE=""

BOARD_NAME=""
DESKTOP="xfce"
RELEASE="stable"
DISTRO="debian"
DISK_SIZE_GB=8

print_usage() {
    echo "usage: ./build_complete.sh <board_name> [options]"
    echo ""
    echo "options:"
    echo "  desktop=name    desktop environment (default: xfce)"
    echo "  release=name    debian release (default: stable)"
    echo "  distro=name     linux distribution (default: debian)"
    echo "  size=gb         disk image size in gigabytes (default: 8)"
    echo ""
    echo "valid desktop values: gnome, xfce, kde, lxde, gnome-flashback, cinnamon, mate, lxqt"
    echo "valid release values: stable, testing, unstable, trixie"
    echo "valid distro values: debian, alpine"
}

parse_arguments() {
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            desktop=*)
                DESKTOP="${args[$i]#desktop=}"
                ;;
            release=*)
                RELEASE="${args[$i]#release=}"
                ;;
            distro=*)
                DISTRO="${args[$i]#distro=}"
                ;;
            size=*)
                DISK_SIZE_GB="${args[$i]#size=}"
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                if [ -z "$BOARD_NAME" ]; then
                    BOARD_NAME="${args[$i]}"
                fi
                ;;
        esac
        i=$((i+1))
    done
}

validate_arguments() {
    if [ -z "$BOARD_NAME" ]; then
        echo "error: board name is required"
        print_usage
        exit 1
    fi
    
    if ! [[ "$DISK_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE_GB" -lt 4 ]; then
        echo "error: disk size must be a number >= 4"
        exit 1
    fi
    
    local valid_desktops="gnome xfce kde lxde gnome-flashback cinnamon mate lxqt"
    local desktop_valid=0
    for d in $valid_desktops; do
        if [ "$DESKTOP" = "$d" ]; then
            desktop_valid=1
            break
        fi
    done
    if [ $desktop_valid -eq 0 ]; then
        echo "error: invalid desktop '$DESKTOP'"
        exit 1
    fi
    
    if [ "$DISTRO" != "debian" ] && [ "$DISTRO" != "alpine" ]; then
        echo "error: invalid distro '$DISTRO'"
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    local deps="wget tar gzip dd parted mkfs.ext4 mkfs.vfat losetup debootstrap arch-chroot"
    
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "missing dependency: $dep"
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        echo "install missing dependencies with: apt install debootstrap parted dosfstools"
        exit 1
    fi
}

setup_work_directory() {
    echo "setting up work directory..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$SHIM_DIR"
    mkdir -p "$ROOTFS_DIR"
    mkdir -p "$BOOT_DIR"
}

create_disk_image() {
    echo "creating disk image: $IMAGE_FILE ($DISK_SIZE_GB GB)"
    
    # create empty image file
    dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=$((DISK_SIZE_GB * 1024)) status=progress
    
    # create partition table
    parted -s "$IMAGE_FILE" mklabel msdos
    parted -s "$IMAGE_FILE" mkpart primary fat32 1MiB 512MiB
    parted -s "$IMAGE_FILE" mkpart primary ext4 512MiB 100%
    parted -s "$IMAGE_FILE" set 1 boot on
    
    # attach loop device
    LOOP_DEVICE=$(losetup --find --show -P "$IMAGE_FILE")
    echo "loop device: $LOOP_DEVICE"
    
    sleep 1
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 1
    
    # format partitions
    local boot_part="${LOOP_DEVICE}p1"
    local root_part="${LOOP_DEVICE}p2"
    
    echo "formatting boot partition..."
    mkfs.vfat -F 32 -n "SHIMBOOT" "$boot_part"
    
    echo "formatting root partition..."
    mkfs.ext4 -L "SHIMROOT" "$root_part"
    
    # mount root partition
    mount "$root_part" "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR/boot"
    
    # mount boot partition
    mount "$boot_part" "$ROOTFS_DIR/boot"
    
    # store partition uuid for boot configuration
    ROOT_UUID=$(blkid -o value -s UUID "$root_part")
    BOOT_UUID=$(blkid -o value -s UUID "$boot_part")
}

download_rma_shim() {
    echo "downloading rma shim for board: $BOARD_NAME"
    
    local shim_urls=(
        "https://dl.darkn.bio/rma_shims/${BOARD_NAME}.tar.xz"
        "https://web.archive.org/web/20240101000000/https://dl.darkn.bio/rma_shims/${BOARD_NAME}.tar.xz"
    )
    
    local shim_archive="${WORK_DIR}/shim.tar.xz"
    local downloaded=0
    
    for url in "${shim_urls[@]}"; do
        echo "attempting: $url"
        if wget -q --timeout=30 --tries=2 -O "$shim_archive" "$url" 2>/dev/null; then
            if tar -tf "$shim_archive" >/dev/null 2>&1; then
                downloaded=1
                break
            fi
        fi
    done
    
    if [ $downloaded -eq 0 ]; then
        echo "error: failed to download rma shim for board '$BOARD_NAME'"
        echo "board names: https://chrome100.dev/"
        exit 1
    fi
    
    echo "extracting rma shim..."
    tar -xf "$shim_archive" -C "$SHIM_DIR"
    
    local shim_bin=$(find "$SHIM_DIR" -name "*.bin" -type f | head -1)
    if [ -z "$shim_bin" ]; then
        shim_bin=$(find "$SHIM_DIR" -type f -exec file {} \; | grep -i "x86.*boot" | cut -d: -f1 | head -1)
    fi
    
    if [ -z "$shim_bin" ]; then
        echo "error: no shim binary found"
        exit 1
    fi
    
    export SHIM_BIN_PATH="$shim_bin"
}

patch_shim_for_boot() {
    echo "patching shim for sd card boot using PARTUUID..."
    
    local loop_shim=$(losetup --find --show -P "$SHIM_BIN_PATH")
    local kernel_part=""
    
    for part in "${loop_shim}p1" "${loop_shim}p2" "${loop_shim}p3"; do
        if [ -b "$part" ]; then
            local part_type=$(blkid -o value -s TYPE "$part" 2>/dev/null)
            if [ "$part_type" = "vfat" ]; then
                kernel_part="$part"
                break
            fi
        fi
    done
    
    if [ -z "$kernel_part" ]; then
        losetup -d "$loop_shim"
        echo "error: could not find kernel partition in shim"
        exit 1
    fi
    
    local kernel_mount="${WORK_DIR}/kernel_mount"
    mkdir -p "$kernel_mount"
    mount "$kernel_part" "$kernel_mount"
    
    local kernel_file=$(find "$kernel_mount" -name "vmlinuz*" | head -1)
    local initrd_file=$(find "$kernel_mount" -name "initrd*" | head -1)
    
    if [ -n "$kernel_file" ]; then
        cp "$kernel_file" "$BOOT_DIR/vmlinuz"
        echo "kernel copied"
    fi
    
    if [ -n "$initrd_file" ]; then
        cp "$initrd_file" "$BOOT_DIR/initrd.img"
        echo "initrd copied"
    fi
    
    umount "$kernel_mount"
    losetup -d "$loop_shim"
    rm -rf "$kernel_mount"
    
    # create extlinux configuration using PARTUUID for sd card compatibility
    mkdir -p "${BOOT_DIR}/extlinux"
    
    # PARTUUID is derived from the partition table and works regardless of
    # whether the device appears as /dev/sda (usb) or /dev/mmcblk0 (sd card)
    cat > "${BOOT_DIR}/extlinux/extlinux.conf" << EOF
default shimboot
label shimboot
    kernel /vmlinuz
    initrd /initrd.img
    append root=PARTUUID=${ROOT_PARTUUID} rootwait rw console=tty1 console=ttyS0 quiet
EOF
}

build_debian_rootfs() {
    echo "building debian rootfs..."
    
    local debian_suite=""
    case "$RELEASE" in
        stable)     debian_suite="bookworm" ;;
        testing)    debian_suite="trixie" ;;
        unstable)   debian_suite="sid" ;;
        trixie)     debian_suite="trixie" ;;
        *)          debian_suite="bookworm" ;;
    esac
    
    echo "deboostrapping debian $debian_suite..."
    debootstrap --arch amd64 "$debian_suite" "$ROOTFS_DIR" http://deb.debian.org/debian/
    
    # get root partition PARTUUID from the loop device
    ROOT_PARTUUID=$(blkid -o value -s PARTUUID "${LOOP_DEVICE}p2")
    
    cat > "$ROOTFS_DIR/etc/fstab" << EOF
proc /proc proc defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
/dev/disk/by-partuuid/${ROOT_PARTUUID} / ext4 defaults,noatime 0 1
EOF
    
    echo "shimboot" > "$ROOTFS_DIR/etc/hostname"
    
    cat > "$ROOTFS_DIR/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian $debian_suite main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security $debian_suite-security main contrib non-free
deb http://deb.debian.org/debian $debian_suite-updates main contrib non-free
EOF
    
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    
    chroot "$ROOTFS_DIR" /bin/bash << CHROOT_EOF
set -e
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y linux-image-amd64 firmware-linux firmware-linux-nonfree
apt install -y extlinux initramfs-tools

case "$DESKTOP" in
    gnome)
        apt install -y gnome-core gdm3 network-manager-gnome
        systemctl enable gdm3
        ;;
    xfce)
        apt install -y xfce4 xfce4-goodies lightdm network-manager-gnome
        systemctl enable lightdm
        ;;
    kde)
        apt install -y kde-plasma-desktop plasma-nm sddm
        systemctl enable sddm
        ;;
    lxde)
        apt install -y lxde lightdm
        systemctl enable lightdm
        ;;
    cinnamon)
        apt install -y cinnamon lightdm
        systemctl enable lightdm
        ;;
    mate)
        apt install -y mate-desktop mate-desktop-environment
        ;;
    lxqt)
        apt install -y lxqt sddm
        systemctl enable sddm
        ;;
esac

apt install -y network-manager sudo xorg xinit
useradd -m -G sudo,audio,video,netdev -s /bin/bash user
echo "user:user" | chpasswd
echo "user ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/user
systemctl enable NetworkManager
systemctl set-default graphical.target
CHROOT_EOF
    
    umount "$ROOTFS_DIR/dev"
    umount "$ROOTFS_DIR/proc"
    umount "$ROOTFS_DIR/sys"
    
    # install bootloader inside the image
    chroot "$ROOTFS_DIR" extlinux --install /boot/extlinux
    dd if=/usr/lib/syslinux/mbr.bin of="$LOOP_DEVICE" bs=440 count=1 2>/dev/null || true
}

build_alpine_rootfs() {
    echo "building alpine rootfs..."
    
    local alpine_version="v3.19"
    local alpine_tar="alpine-minirootfs-${alpine_version}-x86_64.tar.gz"
    local alpine_url="http://dl-cdn.alpinelinux.org/alpine/${alpine_version}/releases/x86_64/${alpine_tar}"
    
    ROOT_PARTUUID=$(blkid -o value -s PARTUUID "${LOOP_DEVICE}p2")
    
    rm -rf "$ROOTFS_DIR"/*
    wget -q -O "$WORK_DIR/$alpine_tar" "$alpine_url"
    tar -xzf "$WORK_DIR/$alpine_tar" -C "$ROOTFS_DIR"
    
    cat > "$ROOTFS_DIR/etc/fstab" << EOF
/dev/disk/by-partuuid/${ROOT_PARTUUID} / ext4 defaults,noatime 0 1
proc /proc proc defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
EOF
    
    echo "shimboot" > "$ROOTFS_DIR/etc/hostname"
    
    echo "http://dl-cdn.alpinelinux.org/alpine/${alpine_version}/main" > "$ROOTFS_DIR/etc/apk/repositories"
    echo "http://dl-cdn.alpinelinux.org/alpine/${alpine_version}/community" >> "$ROOTFS_DIR/etc/apk/repositories"
    
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    
    chroot "$ROOTFS_DIR" /bin/sh << CHROOT_EOF
apk update
apk add linux-lts linux-firmware
apk add sudo alpine-base openssh
apk add xorg-server xf86-video-vesa xf86-input-evdev
apk add eudev dbus elogind
apk add networkmanager networkmanager-cli
rc-update add NetworkManager
rc-update add dbus
CHROOT_EOF
    
    umount "$ROOTFS_DIR/dev"
    umount "$ROOTFS_DIR/proc"
}

finalize_image() {
    echo "finalizing disk image..."
    
    sync
    sleep 2
    
    umount "$ROOTFS_DIR/boot"
    umount "$ROOTFS_DIR"
    losetup -d "$LOOP_DEVICE"
    
    echo "=========================================="
    echo "build complete!"
    echo "image file: $IMAGE_FILE"
    echo ""
    echo "write to sd card with:"
    echo "  sudo dd if=$IMAGE_FILE of=/dev/mmcblkX bs=4M status=progress"
    echo ""
    echo "replace /dev/mmcblkX with your sd card device"
    echo "for usb drives: sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
    echo "=========================================="
}

main() {
    if [ "$EUID" -ne 0 ]; then
        echo "error: this script must be run as root"
        exit 1
    fi
    
    parse_arguments "$@"
    validate_arguments
    check_dependencies
    setup_work_directory
    create_disk_image
    download_rma_shim
    patch_shim_for_boot
    
    if [ "$DISTRO" = "debian" ]; then
        build_debian_rootfs
    elif [ "$DISTRO" = "alpine" ]; then
        build_alpine_rootfs
    fi
    
    finalize_image
}

main "$@"
