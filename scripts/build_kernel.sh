#!/bin/bash
set -euo pipefail

# =============================================================================
# V8.1-D2 : KernelSU-Next + SUSFS (fork 4.19) + manual hooks
#           - Intègre le module via le fork wshamroukh
#           - Applique susfs_inline_hook_patches.sh (JackA1ltman) pour les hooks
# =============================================================================

echo "=== Build KernelSU-Next + SUSFS (4.19) — V8.1-D2 ==="
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

# ==================== 1. CLONAGE NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION MODULE KernelSU-Next (fork 4.19) ====================
echo "=== Intégration module KernelSU-Next ==="
git clone --depth=1 --branch ksun-v3.4.0-legacy-susfs-v2.3.0 \
  https://github.com/wshamroukh/KernelSU-Next-SUSFS-kernelv4.19.git KernelSU-Next-4.19

mkdir -p drivers/kernelsu
cp -r KernelSU-Next-4.19/kernel/* drivers/kernelsu/
cp -r KernelSU-Next-4.19/uapi drivers/kernelsu/

# Enregistrement dans le noyau
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
echo "✅ module copié et enregistré"

# ==================== 3. APPLICATION DES MANUAL HOOKS (JackA1ltman) ====================
echo ""
echo "=== Application des manual hooks (susfs_inline_hook_patches.sh) ==="

# Télécharger le script de patchs
curl -LSs "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/susfs_inline_hook_patches.sh" -o /tmp/hooks.sh
chmod +x /tmp/hooks.sh

# Le script doit être exécuté depuis la racine du noyau
bash /tmp/hooks.sh

echo ""
echo "=== Vérification des hooks insérés ==="
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c drivers/input/input.c; do
    if grep -q 'ksu_handle' "$f"; then
        echo "  ✅ $f contient des appels ksu_handle"
    else
        echo "  ⚠️  $f ne contient AUCUN appel ksu_handle"
    fi
done

# Vérification critique : le hook execve doit être présent
if grep -q 'ksu_handle_execveat' fs/exec.c; then
    echo "✅ Hook execve présent"
else
    echo "❌ Hook execve MANQUANT — le build va échouer"
    exit 1
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
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_WITH_KPROBES is not set
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
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

# Vérification
grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ CONFIG_KSU"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK=y' out/.config || echo "⚠️  MANUAL_HOOK non activé"
echo "✅ configuration validée"

# ==================== 5. PATCHS MOTOROLA ====================
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
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -40
    exit 1
fi

# ==================== 7-10. KSUD + REPACK + DIAG + SORTIE ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly
rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

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
[ -z "$KSUD_BINARY" ] && echo "❌ ksud introuvable" && exit 1
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

echo "=== Repack ==="
rm -f ./boot-stock.img ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
[ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ] && { echo "❌ boot invalide"; exit 1; }
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib

cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    H=$(sha256sum kernel | cut -d' ' -f1); C=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$H" = "$C" ] && echo "✅ Noyau IDENTIQUE"
fi
cd ..

mkdir -p output
cp final_boot.img output/KernelSU-Next-SUSFS-v4.19-v8.1-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v8.1-D2 ==="
ls -lh output/
