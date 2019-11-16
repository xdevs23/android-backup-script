#!/bin/bash -e

use_adb_root=false

if [[ $# -gt 0 ]]; then
    case "$1" in
        help|-h|--help)
            echo "Makes a full backup over ADB"
            echo "tar /data, binary img /data block"
            exit 0
            ;;
        --use-adb-root)
            use_adb_root=true
            ;;
        *)
            echo "Unknown argument $1"
            exit 1
            ;;
    esac
fi

if [ ! -d busybox-ndk ]; then
    git clone https://github.com/Magisk-Modules-Repo/busybox-ndk
else
    pushd busybox-ndk
    git pull
    popd
fi

echo "Waiting for device..."
adb wait-for-any

echo "Devices detected:"
adb devices

echo "Checking for root access..."
if [ $(adb shell whoami) != "root" ]; then
    echo "Need root access. Please use TWRP for this!"
    if $use_adb_root; then
        echo "Requesting root..."
        adb root
        echo "Waiting for device..."
        adb wait-for-any
    else
        exit 1
    fi
fi

echo "Checking for presence of /data"
if ! [ "$(adb shell ls /data/ | wc -l)" -gt 1 ]; then
    adb shell mount /data
fi

if ! [ "$(adb shell ls /data/ | wc -l)" -gt 4 ]; then
    echo "It seems like /data is not in a sane state!"
    adb shell ls /data || :
    adb shell stat /data || :
    exit 1
fi

echo "Determining architecture..."
target_arch="$(adb shell uname -m)"
case $target_arch in
    aarch64|arm64|armv8|armv8a)
        target_arch=arm64
        ;;
    aarch32|arm32|arm|armv7|armv7a|arm-neon|armv7a-neon|aarch|ARM)
        target_arch=arm
        ;;
    mips|MIPS|mips32|arch-mips32)
        target_arch=mips
        ;;
    x86|x86_32|IA32|ia32|intel32|i386|i486|i586|i686|intel)
        target_arch=x86
        ;;
    x86_64|x64|amd64|AMD64|amd)
        target_arch=x86_64
        ;;
    *)
        echo "Unrecognized architecture $target_arch"
        exit 1
        ;;
esac

echo "Pushing busybox to device..."
adb push busybox-ndk/busybox-$target_arch /sbin/busybox
if ! adb shell busybox >/dev/null; then
    echo "Busybox doesn't work here!"
    exit 1
fi

backup_name="backup-$(date +'%Y%m%d-%H%M%S')"
mkdir -p "$backup_name"
pushd "$backup_name"

echo "Remounting data read-only"
adb shell mount -o remount,ro /data

echo "Creating full tar backup of /data"
adb shell 'busybox tar -cv -C /data . | gzip -c7' | gzip -d | pv -trabi 1 | gzip -c9 > data.tar.gz

echo "Creating image backup..."
adb shell 'dd if=/dev/block/bootdevice/by-name/userdata bs=16777216 | gzip -c7' gzip -d | pv -trabi 1 | gzip -c9 > data.img.gz

echo "Verifying image backup..."
echo -n "  Calculate checksum on device: "
device_checksum="$(adb shell busybox sha256sum /dev/block/bootdevice/by-name/userdata | cut -d ' ' -f1)"
echo "$device_checksum"
echo -n "  Calculate checksum locally: "
local_checksum="$(gzip -d < data.img.gz | sha256sum | cut -d ' ' -f1)"
echo "$local_checksum"

if [ "$local_checksum" == "$device_checksum" ]; then
    echo "Checksums match."
else
    echo -e "\033[1mChecksums don't match! $local_checksum != $device_checksum\033[0m"
fi

echo "Creating backup of important app data..."
mkdir -p device_data
pushd device_data

echo "  - Google Authenticator"
adb pull /data/data/com.google.android.apps.authenticator2 ./
echo "  - Password Store"
adb pull /data/data/com.zeapo/pwdstore ./
echo "  - OpenKeyChain"
adb pull /data/data/org.sufficientlysecure.keychain ./
echo "  - VR SecureGo"
adb pull /data/data/de.fiducia.smartphone.securego.vr ./
echo "  - VR Wallet"
adb pull /data/data/de.fiduciagad.android.vrwallet ./
echo "  - VR Banking"
adb pull /data/data/de.fiducia.smartphone.android.banking.vr ./

popd # device_data

mkdir -p device_misc
pushd device_misc

adb pull /data/misc/. .

popd # device_misc

if adb shell busybox [ -d /data/unencrypted ]; then
    mkdir -p unencrypted
    pushd

    adb pull /data/unencrypted/. .

    popd # unencrypted
fi

popd # $backup_name

