#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.30 : SukiSU-Ultra builtin + SUSFS v2.3.0 (fix kfree_rcu NULL — 16cb19c)
#         Méthode JackA1ltman / NonGKI_Kernel_Build_2nd / mainline
# =============================================================================

echo "=== Build SukiSU-Ultra builtin — V7.30 (JackA1ltman) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"

# -----------------------------------------------------------------------------
# 0. Dépendances
# -----------------------------------------------------------------------------
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential flex libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip cpio patch wget

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# -----------------------------------------------------------------------------
# 1. Clone noyau
# -----------------------------------------------------------------------------
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
  -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# -----------------------------------------------------------------------------
# 2. SukiSU-Ultra builtin (ShirkNeko)
# -----------------------------------------------------------------------------
echo ""
echo "=== SukiSU-Ultra builtin ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin \
  || { echo "❌ setup.sh SukiSU échoué"; exit 1; }

[ -d drivers/kernelsu ] || { echo "❌ drivers/kernelsu absent"; exit 1; }
echo "✅ SukiSU-Ultra intégré"

# -----------------------------------------------------------------------------
# 2b. Patch SUSFS 4.19 — JackA1ltman (version 16cb19c, fix kfree_rcu NULL)
# -----------------------------------------------------------------------------
echo ""
echo "=== Patch SUSFS 4.19 (JackA1ltman, fix kfree_rcu) ==="
BASE_JACK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches"

SUSFS_PATCH="/tmp/susfs_patch_to_4.19.patch"
curl -LSsf "$BASE_JACK/Patch/susfs_patch_to_4.19.patch" -o "$SUSFS_PATCH" \
  || { echo "❌ download patch SUSFS échoué"; exit 1; }
[ -s "$SUSFS_PATCH" ] || { echo "❌ patch SUSFS vide"; exit 1; }

if patch -p1 --forward --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 \
      || { echo "❌ patch SUSFS a échoué"; cat /tmp/susfs_patch.log; exit 1; }
    echo "  ✅ patch SUSFS appliqué"
elif patch -p1 --reverse --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    echo "  ↻ patch SUSFS déjà appliqué"
else
    echo "❌ patch SUSFS ni applicable ni déjà appliqué"
    patch -p1 --forward --reject-file=- < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true
    grep -E '^Hunk|^FAILED|^Reversed' /tmp/susfs_patch.log | head -10 || true
    exit 1
fi

# Vérification fichiers SUSFS
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [ -s "$f" ] || { echo "❌ $f manquant"; exit 1; }
done
echo "  ✅ fichiers SUSFS présents"

# susfs.o dans fs/Makefile (si absent)
if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi

# -----------------------------------------------------------------------------
# 3. Hooks inline — MÉTHODE JACKA1LTMAN
# -----------------------------------------------------------------------------
echo ""
echo "=== Hooks inline (susfs_inline_hook_patches.sh) ==="
HOOK_SCRIPT="/tmp/susfs_inline_hook_patches.sh"
curl -LSsf "$BASE_JACK/susfs_inline_hook_patches.sh" -o "$HOOK_SCRIPT" \
  || { echo "❌ download script hooks échoué"; exit 1; }
[ -s "$HOOK_SCRIPT" ] || { echo "❌ script hooks vide"; exit 1; }
chmod +x "$HOOK_SCRIPT"

bash "$HOOK_SCRIPT" || { echo "❌ injection hooks échouée"; exit 1; }
echo "✅ hooks injectés"

# -----------------------------------------------------------------------------
# 4. Config
# -----------------------------------------------------------------------------
echo ""
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU_FEATURE_SULOG=y
CONFIG_KSU_FEATURE_ADBROOT=y

CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
# CONFIG_KSU_SUSFS_SUS_MOUNT is not set
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set
CONFIG_KSU_SUSFS_SUS_MAP=y

CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_THREAD_INFO_IN_TASK=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  olddefconfig 2>&1 | tail -3

# Vérif config critique
for opt in CONFIG_KSU CONFIG_KSU_MANUAL_HOOK CONFIG_KSU_SUSFS \
           CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_KSTAT; do
    grep -q "^${opt}=y" out/.config || { echo "❌ ${opt} droppé"; exit 1; }
done
echo "✅ config validée"

# -----------------------------------------------------------------------------
# 5. Patch Motorola (tactile)
# -----------------------------------------------------------------------------
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
MSM_DRV="techpack/display/msm/msm_drv.c"
if [ -f "$MSM_DRV" ]; then
    printf '\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n' >> "$MSM_DRV"
fi

# -----------------------------------------------------------------------------
# 6. Compilation
# -----------------------------------------------------------------------------
echo ""
echo "=== Compilation ==="
set +eo pipefail
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" \
  -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -30 || true
    exit 1
fi
echo "✅✅✅ COMPILATION RÉUSSIE (V7.30) ✅✅✅"

# -----------------------------------------------------------------------------
# 7. Sauvegarde
# -----------------------------------------------------------------------------
mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.30-susfs"
[ -f out/System.map ] && cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.30-susfs"

# -----------------------------------------------------------------------------
# 8. Repack
# -----------------------------------------------------------------------------
echo ""
echo "=== Repack ==="
cd "$GITHUB_WORKSPACE"
rm -f boot-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img || true

if [ ! -f boot-stock.img ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img introuvable — Image sauvée dans output/"
    exit 0
fi

mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib

cd repack
./magiskboot unpack boot.img
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v7.30-boot.img"
cd "$GITHUB_WORKSPACE"
echo "✅ boot.img repacké"

# -----------------------------------------------------------------------------
# 9. Sortie
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ v7.30 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
