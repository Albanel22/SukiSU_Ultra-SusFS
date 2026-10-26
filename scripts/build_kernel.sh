#!/bin/bash
set -euo pipefail

# =============================================================================
# V8.0-D2 : KernelSU-Next + SUSFS (fork 4.19 de wshamroukh)
#           - Remplace SukiSU-Ultra par KernelSU-Next legacy
#           - SUSFS déjà intégré (v2.3.0)
#           - Injection SELinux fonctionnelle (struct policydb)
# =============================================================================

echo "=== Build KernelSU-Next + SUSFS (4.19) — V8.0-D2 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION KernelSU-Next (fork 4.19 + SUSFS) ====================
echo "=== Intégration KernelSU-Next-SUSFS-kernelv4.19 ==="

# Cloner le fork dédié 4.19
git clone --depth=1 --branch ksun-v3.4.0-legacy-susfs-v2.3.0 \
  https://github.com/wshamroukh/KernelSU-Next-SUSFS-kernelv4.19.git KernelSU-Next-4.19

# Créer drivers/kernelsu et copier le code noyau
mkdir -p drivers/kernelsu
cp -r KernelSU-Next-4.19/kernel/* drivers/kernelsu/
cp -r KernelSU-Next-4.19/uapi drivers/kernelsu/

# Vérification des fichiers clés
echo "--- Vérification drivers/kernelsu ---"
for f in "drivers/kernelsu/Kconfig" "drivers/kernelsu/Makefile" \
         "drivers/kernelsu/selinux/rules.c" "drivers/kernelsu/selinux/sepolicy.c"; do
    [ -f "$f" ] && echo "  ✅ $f" || echo "  ❌ $f"
done

# ==================== 3. ENREGISTREMENT DANS LE NOYAU ====================
echo ""
echo "=== Enregistrement dans drivers/Kconfig et drivers/Makefile ==="

# Kconfig
if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
    echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
    echo "  ✅ drivers/Kconfig modifié"
else
    echo "  ✅ drivers/Kconfig déjà présent"
fi

# Makefile
if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    echo "  ✅ drivers/Makefile modifié"
else
    echo "  ✅ drivers/Makefile déjà présent"
fi

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration KernelSU-Next + SUSFS ==="

export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
# KernelSU-Next
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_DEBUG=n
CONFIG_KSU_DISABLE_MANAGER=n
CONFIG_KSU_DISABLE_POLICY=n
CONFIG_KSU_ALLOWLIST_WORKAROUND=n

# KernelSU - SUSFS
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=n
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  olddefconfig 2>&1 | tail -3

echo "=== État .config (KSU + SUSFS) ==="
grep -E "CONFIG_KSU=y|CONFIG_KSU_MANUAL_HOOK=y|CONFIG_KSU_SUSFS=y|CONFIG_THREAD_INFO_IN_TASK=y" out/.config || true

# Vérifier que THREAD_INFO_IN_TASK est activé (dépendance de SUSFS)
if ! grep -q '^CONFIG_THREAD_INFO_IN_TASK=y' out/.config; then
    echo "⚠️  THREAD_INFO_IN_TASK absent — activation forcée"
    echo 'CONFIG_THREAD_INFO_IN_TASK=y' >> out/.config
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig > /dev/null 2>&1
fi

if ! grep -q '^CONFIG_KSU=y' out/.config; then
    echo "❌ CONFIG_KSU non activé, abandon"; exit 1
fi

# ==================== 5. PATCHS MOTOROLA (tactile / signatures) ====================
echo "=== Patchs Motorola ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* Patch Tactile */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c
echo "✅"

# ==================== 6. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -40
    exit 1
fi

# ==================== 7. COMPILATION KSUD (userspace KernelSU-Next) ====================
echo ""
echo "=== Compilation ksud (KernelSU-Next) ==="
cd "$GITHUB_WORKSPACE"

# Installer Rust + NDK (même méthode que pour SukiSU)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

# Cloner le userspace officiel KernelSU-Next
rm -rf "$GITHUB_WORKSPACE/ksunext-src"
git clone --depth=1 --branch next https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksunext-src"
cd "$GITHUB_WORKSPACE/ksunext-src/userspace/ksud"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksunext-src" -type f -name "ksud" -executable 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK ====================
echo ""
echo "=== Repack boot.img ==="

rm -f ./boot-stock.img ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib 2>/dev/null || true

cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. DIAGNOSTIC ====================
echo ""
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
fi
if [ -f "ramdisk.cpio" ]; then
    if ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null; then
        echo "  ✅ ksud présent dans /data/adb/ksud/"
    else
        echo "  ❌ ksud absent"
    fi
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/KernelSU-Next-SUSFS-v4.19-v8.0-D2-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v8.0-D2 ==="
ls -lh output/
