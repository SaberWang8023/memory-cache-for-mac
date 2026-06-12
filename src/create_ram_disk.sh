#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Ramdisk size in GB.
SIZE_GB=2
SIZE=$((SIZE_GB * 1024))
DISK_NAME=Ramdisk
MOUNT_PATH="/Volumes/$DISK_NAME"

if mount | grep -Fq " on $MOUNT_PATH "; then
  echo "Ramdisk is already mounted at $MOUNT_PATH"
  exit 0
fi

if [ -d "$MOUNT_PATH" ] && [ -z "$(ls -A "$MOUNT_PATH" 2>/dev/null)" ]; then
  rmdir "$MOUNT_PATH"
fi

DISK_ID=$(hdiutil attach -nomount "ram://$(( SIZE * 1024 * 1024 / 512 ))" | awk 'NR==1 { print $1 }') || {
  echo "hdiutil attach failed"
  exit 1
}

[ -n "$DISK_ID" ] || {
  echo "Could not get ramdisk device id"
  exit 1
}

diskutil partitionDisk "$DISK_ID" GPT APFS "$DISK_NAME" 0 || {
  echo "diskutil partitionDisk failed"
  exit 1
}

cd "$MOUNT_PATH" || {
  echo "Could not enter $MOUNT_PATH"
  exit 1
}

mkdir -p Cache/Chrome
