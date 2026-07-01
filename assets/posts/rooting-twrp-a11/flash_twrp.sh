#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
step=0

msg()  { echo -e "${GREEN}[${BOLD}+${NC}${GREEN}]${NC} $1"; }
warn() { echo -e "${YELLOW}[${BOLD}!${NC}${YELLOW}]${NC} $1"; }
err()  { echo -e "${RED}[${BOLD}x${NC}${RED}]${NC} $1"; }
next() { step=$((step+1)); echo -e "\n${BOLD}--- Langkah $step:${NC} $1"; }

cleanup() {
    local rc=$?
    [ $rc -ne 0 ] && echo -e "\n${RED}[!] SCRIPT GAGAL (exit=$rc)${NC}"
    exit $rc
}
trap cleanup EXIT
trap '' SIGINT

echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Flash TWRP 3.7.0 — Samsung A11 (a11q)    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"

# ============================================================
next "Cek ADB & koneksi device"
# ============================================================
! command -v adb &>/dev/null && { err "adb tidak ditemukan"; exit 1; }
msg "ADB: $(adb --version 2>&1 | head -1)"

DEV=$(adb get-state 2>/dev/null || true)
[ "$DEV" != "device" ] && { err "Device tidak terdeteksi"; exit 1; }

MODEL=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
BUILD=$(adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')
msg "$MODEL${BUILD:+ ($BUILD)}"

# ============================================================
next "Cek security properties"
# ============================================================
FL=$(adb shell "getprop ro.boot.flash.locked" 2>/dev/null | tr -d '\r')
VB=$(adb shell "getprop ro.boot.verifiedbootstate" 2>/dev/null | tr -d '\r')
SB=$(adb shell "getprop ro.boot.secureboot" 2>/dev/null | tr -d '\r')
KG=$(adb shell "getprop ro.boot.kgstate" 2>/dev/null | tr -d '\r')
WB=$(adb shell "getprop ro.boot.warranty_bit" 2>/dev/null | tr -d '\r')

echo "  flash.locked         = $FL"
echo "  verifiedbootstate    = $VB"
echo "  secureboot           = $SB"
echo "  kgstate              = $KG"
echo "  warranty_bit         = $WB"

[ "$FL" != "0" ] && { err "Bootloader terkunci! Unlock dulu."; exit 1; }

if [ "$KG" = "prenormal" ] || [ "$KG" = "PRENORMAL" ]; then
    err "KG PRENORMAL — butuh 7 hari + WiFi + Samsung account dulu."
    echo "  OEM Unlock harus muncul di Developer Options."
    exit 1
fi

if [ "$VB" = "green" ]; then
    warn "verifiedbootstate = green (stock image detected)"
    warn "  Bootloader mungkin tidak benar-benar unlock."
    echo -n "  Lanjut? [y/N] "; read -r ans
    [[ "$ans" != [yY] ]] && exit 1
fi

[ -z "$KG" ] && msg "KG state: (tidak ada — normal)"

# ============================================================
next "Cek akses root (su)"
# ============================================================
set +e
ROOT_CHECK=$(adb shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')
set -e

if [ "$ROOT_CHECK" != "0" ]; then
    err "Root (su) tidak tersedia."
    echo "  Root dulu lewat Magisk sebelum jalanin script ini."
    echo
    echo "  Cara root dari Download Mode:"
    echo "  1. Buka Odin (PC)"
    echo "  2. AP slot ← magisk_patched.img (patch stock_boot.img pake Magisk app)"
    echo "  3. Jangan centang Auto Reboot"
    echo "  4. Flash, lalu cabut USB (tahan Vol Down + Power sampe mati)"
    echo "  5. Langsung masuk Recovery (Vol Up + Power)"
    echo "  6. Wipe data/factory reset"
    echo "  7. Reboot system — root aktif"
    exit 1
fi
msg "Root akses OK"

# ============================================================
next "Cek OEM unlock enggak ilang lagi"
# ============================================================
# Kadang setelah flash stock, OEM Unlock toggle ilang.
# Kalo ilang, flashing via Heimdall bakal ditolak.
# Kita cek dengan coba baca partition boot sebagai test.
set +e
TEST_BOOT=$(adb shell "su -c 'dd if=/dev/block/by-name/boot bs=512 count=1 2>/dev/null | xxd -l 8 -p'" 2>/dev/null | tr -d ' \r')
set -e

if [[ "$TEST_BOOT" != "414e44524f494421" ]] && [[ "$TEST_BOOT" != "andro"* ]]; then
    # xxd mungkin gak ada, cek pake dd + python
    set +e
    TEST_BOOT2=$(adb shell "su -c 'dd if=/dev/block/by-name/boot bs=8 count=1 2>/dev/null'" 2>/dev/null | python3 -c "import sys; print(sys.stdin.buffer.read()[:8].hex())" 2>/dev/null)
    set -e
    if [ -n "$TEST_BOOT2" ]; then
        TEST_BOOT="$TEST_BOOT2"
    fi
fi

if [ -z "$TEST_BOOT" ]; then
    err "Tidak bisa baca partition boot — kernel block device access?"
    echo "  Coba: adb shell 'su -c ls -la /dev/block/by-name/'"
    exit 1
fi
msg "Partisi boot terbaca — device OK"

# ------------------------------------------------------------
# ⚠️  VBMETA TIDAK DI-SENTUH DI SINI
#     Patch vbmeta harus manual pake heimdall:
#     heimdall flash --VBMETA vbmeta.img --VBMETABAK vbmeta.img
#     (vbmeta.img = 4096 bytes, byte 123 = 03)
# ------------------------------------------------------------

# ============================================================
next "Push file ke device"
# ============================================================
TWRP_IMG="$DIR/recovery.img"

for f in "$TWRP_IMG"; do
    [ ! -f "$f" ] && { err "File tidak ditemukan: $f"; exit 1; }
done

msg "Push recovery.img → /data/local/tmp/"
adb push "$TWRP_IMG" /data/local/tmp/ 2>&1 | sed 's/^/  /'

# ============================================================
next "Backup & disable recovery-from-boot.p"
# ============================================================
set +e
RFP=$(adb shell "su -c 'find /system /vendor /product -name recovery-from-boot* -o -name install-recovery.sh 2>/dev/null'" 2>/dev/null)
set -e

if [ -z "$RFP" ]; then
    warn "recovery-from-boot* tidak ditemukan — mungkin sudah dihapus"
else
    msg "Backup & hapus file restore stock recovery:"
    echo "$RFP" | while IFS= read -r f; do
        f=$(echo "$f" | tr -d '\r')
        echo "  - $f"
        adb shell "su -c '
            mount -o rw,remount /system 2>/dev/null
            mount -o rw,remount /vendor 2>/dev/null
            mount -o rw,remount /product 2>/dev/null
            cp \"$f\" /data/local/tmp/rfb_bak_$(basename "$f") 2>/dev/null
            rm -f \"$f\" 2>/dev/null
            echo OK
        '" 2>/dev/null || true
    done
    msg "Backup di /data/local/tmp/rfb_bak_* ✅"
fi

# ============================================================
next "Cek ukuran partition recovery"
# ============================================================
set +e
PART_SIZE=$(adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/recovery 2>/dev/null || cat /sys/block/$(readlink /dev/block/by-name/recovery 2>/dev/null | sed \"s|.*/||\")/size 2>/dev/null'" 2>/dev/null | tr -d '\r')
PART_DEV=$(adb shell "su -c 'readlink -f /dev/block/by-name/recovery 2>/dev/null'" 2>/dev/null | tr -d '\r')
IMG_SIZE=$(stat -c%s "$DIR/recovery.img" 2>/dev/null)
set -e

echo "  Partition: ${PART_DEV:-mmcblk0p61}"
echo "  Partition size: ${PART_SIZE:-64M}"
echo "  Recovery image: $IMG_SIZE bytes ($(( IMG_SIZE / 1024 / 1024 ))MB)"

if [ -n "$PART_SIZE" ] && [ "$IMG_SIZE" -gt "$PART_SIZE" ] 2>/dev/null; then
    err "Recovery image ($IMG_SIZE) LEBIH BESAR dari partition ($PART_SIZE)!"
    echo "  Cari TWRP yang ukurannya pas."
    exit 1
fi

if [ -z "$PART_DEV" ]; then
    PART_DEV="/dev/block/mmcblk0p61"
    warn "Pakai $PART_DEV (fallback)"
fi

# ============================================================
next "Flash TWRP ke recovery partition"
# ============================================================
msg "Wipe recovery..."
adb shell "su -c 'dd if=/dev/zero of=$PART_DEV bs=1M count=64 2>/dev/null; echo OK'" 2>/dev/null || true

msg "Flash recovery.img..."
adb shell "su -c 'dd if=/data/local/tmp/recovery.img of=$PART_DEV bs=1M 2>/dev/null'" 2>/dev/null || {
    err "Gagal flash recovery"
    exit 1
}

# Verify first 4KB
set +e
adb shell "su -c 'cmp -n 4096 /data/local/tmp/recovery.img $PART_DEV 2>/dev/null'" 2>/dev/null
CMP_EXIT=$?
set -e

if [ $CMP_EXIT -eq 0 ]; then
    msg "✅ Flash OK — TWRP terverifikasi"
else
    warn "Verifikasi mismatch — partition mungkin beda ukuran"
    echo "  Lanjutin aja, mungkin tetap work."
fi

# ============================================================
next "⚠️  REBOOT KE RECOVERY"
# ============================================================
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ☠️  JANGAN BOOT KE SYSTEM!                ║${NC}"
echo -e "${RED}${BOLD}║  Kalo masuk Android, stock recovery        ║${NC}"
echo -e "${RED}${BOLD}║  langsung ke-restore & TWRP ilang.         ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════╝${NC}"

echo ""
echo "Device akan reboot ke recovery dalam 5 detik..."
for i in 5 4 3 2 1; do echo -n "$i... "; sleep 1; done
adb reboot recovery

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  🔴 LANJUTAN DI TWRP:                      ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║                                             ║${NC}"
echo -e "${BOLD}║  1. TWRP muncul (kalo gak: Vol Up+Power)    ║${NC}"
echo -e "${BOLD}║                                             ║${NC}"
echo -e "${BOLD}║  2. Wipe → Format Data → ketik 'yes'       ║${NC}"
echo -e "${BOLD}║     ⚠️  HAPUS semua data internal          ║${NC}"
echo -e "${BOLD}║                                             ║${NC}"
echo -e "${BOLD}║  4. Reboot → Recovery (cek TWRP masih ada)  ║${NC}"
echo -e "${BOLD}║  5. Reboot → System                         ║${NC}"
echo -e "${BOLD}║                                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
