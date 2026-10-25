#!/bin/bash
# Boot the XNU loader + kernel payload under QEMU (virt, GICv3, UEFI at EL1).
# usage: run.sh [seconds] [extra qemu args...]
# env: QEMU_TB_MB           megabytes for QEMU's cache of translated code (default 384; QEMU's own
#                           default of 1 GB mostly costs host memory)
#      QEMU_SMP             processor cores of the machine (default 1); the kernel uses as many of them as
#                           its boot-arg cpus=N says (CMDLINE="cpus=4" for run-ios.sh), one without it
#      QEMU_EFI, QEMU_VARS  the UEFI firmware for aarch64 guests (default: the split code+vars pair of
#                           Arch Linux, Debian/Ubuntu; on macOS (Homebrew) QEMU's own combined aarch64
#                           image: it carries its var store, so it is used in one writable copy)
#      QEMU_CLOCK           QEMU's -rtc base (default: utc; set to local for fast boots with none)
cd "$(dirname "$0")"
T=${1:-20}; shift
TIMEOUT=$(command -v timeout || command -v gtimeout || echo timeout)
EFI=${QEMU_EFI:-$(for p in /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd \
	/usr/share/edk2-arm/AAVMF_CODE.fd /opt/homebrew/share/qemu/edk2-aarch64-code.fd; do
	[ -f $p ] && { echo $p; break; }; done)}
[ -n "$EFI" ] || { echo "run.sh: no UEFI firmware found (set QEMU_EFI and QEMU_VARS)"; exit 1; }
if [ -n "${QEMU_VARS:-}" ] && [ -f "$QEMU_VARS" ]; then
	VARS=$QEMU_VARS
elif [ "$(basename "$EFI")" = edk2-aarch64-code.fd ]; then
	VARS=$EFI                      # the combined image: the var store is inside it, kept writable
else
	VARS=$(dirname "$EFI")/QEMU_VARS.fd 2>/dev/null
	[ -f "$VARS" ] || VARS=$(dirname "$EFI")/AAVMF_VARS.fd
	[ -f "$VARS" ] || { echo "run.sh: no UEFI vars next to $EFI (set QEMU_VARS)"; exit 1; }
fi
cp "$VARS" vars.fd
# the loader is the boot application of the little FAT volume QEMU makes of esp/:
# the one built here, or else the one that comes with the repository
L=../xnuloader/loader.efi; [ -f $L ] || L=../prebuilt/loader.efi
mkdir -p esp/EFI/BOOT && cp $L esp/EFI/BOOT/BOOTAA64.EFI
# the combined image keeps its var store inside itself: it works off one writable copy;
# the split pair is two devices: the code read-only and the vars writable
if [ "$VARS" = "$EFI" ]; then
	PFLASH=(-drive if=pflash,format=raw,file=vars.fd)
else
	PFLASH=(-drive if=pflash,format=raw,readonly=on,file="$EFI" -drive if=pflash,format=raw,file=vars.fd)
fi
$TIMEOUT "$T" qemu-system-aarch64 -M virt,gic-version=3 -cpu cortex-a76 -smp ${QEMU_SMP:-1} -m ${QEMU_MEM:-6G} \
  -accel tcg,tb-size=${QEMU_TB_MB:-384} \
  "${PFLASH[@]}" \
  -drive file=fat:rw:esp,format=raw,if=virtio \
  -device loader,file=payload.bin,addr=0xF0000000,force-raw=on \
  -display none -serial stdio -monitor none -no-reboot "$@" 2>&1
