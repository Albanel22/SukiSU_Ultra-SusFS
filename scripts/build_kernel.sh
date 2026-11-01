#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.58 : SukiSU-Ultra (Base V7.40) + BakaSU ksud + Suppression propre
#         - Supprime la déclaration ET l'appel de la fonction manquante
# =============================================================================

echo "=== Build SukiSU-Ultra — V7.58 ==="
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
# 2. SukiSU-Ultra builtin
# -----------------------------------------------------------------------------
echo ""
echo "=== SukiSU-Ultra builtin ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin \
  || { echo "❌ setup.sh SukiSU échoué"; exit 1; }

[ -d drivers/kernelsu ] || { echo "❌ drivers/kernelsu absent"; exit 1; }
echo "✅ SukiSU-Ultra intégré"

# -----------------------------------------------------------------------------
# 2a. Correctif manager detection (O_CLOEXEC)
# -----------------------------------------------------------------------------
echo ""
echo "=== Correctif manager detection (O_CLOEXEC) ==="
python3 - <<'PYEOF'
import os, re, sys
target_file = None
for root, dirs, files in os.walk('drivers/kernelsu'):
    for file in files:
        if file in ['supercall.c', 'supercalls.c']:
            target_file = os.path.join(root, file)
            break
    if target_file: break

if target_file:
    with open(target_file) as f: c = f.read()
    if 'MSG123' not in c:
        c2, n1 = re.subn(
            r'(int\s+ksu_install_fd\s*\(\s*void\s*\)\s*\{[^}]*?)return\s+ksu_install_fd_with_permissions\s*\(\s*O_CLOEXEC\s*,\s*0\s*\)',
            r'\1return ksu_install_fd_with_permissions(0, 0); /* MSG123 */',
            c, flags=re.DOTALL
        )
        if n1 == 0:
            c2, n1 = re.subn(r'return\s+ksu_install_fd_with_permissions\s*\(\s*O_CLOEXEC\s*,\s*0\s*\)', 'return ksu_install_fd_with_permissions(0, 0); /* MSG123 */', c)
        if n1 > 0:
            with open(target_file, 'w') as f: f.write(c2)
            print(f"  ✅ {target_file} : corrigé")
PYEOF

# -----------------------------------------------------------------------------
# 2b. Patch SUSFS 4.19
# -----------------------------------------------------------------------------
echo ""
echo "=== Patch SUSFS 4.19 ==="
BASE_JACK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches"
SUSFS_PATCH="/tmp/susfs_patch_to_4.19.patch"
curl -LSsf "$BASE_JACK/Patch/susfs_patch_to_4.19.patch" -o "$SUSFS_PATCH" || { echo "❌ download échoué"; exit 1; }

if patch -p1 --forward --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1
    echo "  ✅ patch appliqué"
else
    echo "  ⚠️ Patch partiellement rejeté"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true
fi

# Injection manuelle namespace.c
python3 - <<'PYEOF'
import re, sys
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
if 'susfs_is_current_ksu_domain' in c: sys.exit(0)
anchor1 = '#include "internal.h"\n'
bloc1 = '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif\n'
c = c.replace(anchor1, anchor1 + bloc1, 1)
pattern = r'(struct vfsmount \*vfs_kern_mount\([^)]*\)\s*\{.*?if \(!type\)\s*\n\s*return ERR_PTR\(-EINVAL\);\s*\n)'
match = re.search(pattern, c, re.DOTALL)
bloc2 = '\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {\n\t\tif (susfs_is_current_ksu_domain()) {\n\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");\n\t\t\tgoto bypass_orig_flow;\n\t\t}\n\t}\n#endif\n'
c = c[:match.end()] + bloc2 + c[match.end():]
pattern2 = r'(mnt = alloc_vfsmnt\(name\);\s*\n)'
match2 = re.search(pattern2, c)
label = '\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbypass_orig_flow:\n#endif\n'
c = c[:match2.end()] + label + c[match2.end():]
with open(path, 'w') as f: f.write(c)
PYEOF

python3 - <<'PYEOF'
import sys
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
if '#define DEFAULT_KSU_MNT_ID' not in c and 'DEFAULT_KSU_MNT_ID' in c:
    anchor = '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */'
    c = c.replace(anchor, anchor + '\n#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n', 1) if anchor in c else '#define DEFAULT_KSU_MNT_ID 500000\n' + c
    with open(path, 'w') as f: f.write(c)
PYEOF

find . -name "*.rej" -delete 2>/dev/null || true
if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi

# -----------------------------------------------------------------------------
# 2c. 🚨 FIX PROPRE : Suppression de la déclaration ET de l'appel
# -----------------------------------------------------------------------------
echo ""
echo "=== FIX PROPRE : Suppression déclaration + appel ==="
python3 - <<'PYEOF'
import os, re, sys

target_file = None
for root, dirs, files in os.walk('drivers/kernelsu'):
    if 'sepolicy.c' in files:
        target_file = os.path.join(root, 'sepolicy.c')
        break

if not target_file:
    print("  ⚠️ sepolicy.c introuvable, skip")
    sys.exit(0)

with open(target_file, 'r') as f:
    c = f.read()

if 'SUSFS_AVD_DECL_REMOVED' in c:
    print(f"  ↻ {target_file} : déjà patché")
    sys.exit(0)

# 1. Supprimer la déclaration
c, n1 = re.subn(
    r'extern\s+int\s+susfs_add_sus_avd_allowed_by_type\s*\([^;]*\);',
    '/* SUSFS_AVD_DECL_REMOVED */',
    c
)

# 2. Supprimer l'appel
c, n2 = re.subn(
    r'susfs_add_sus_avd_allowed_by_type\s*\([^;]*\);',
    '/* SUSFS_AVD_CALL_REMOVED */',
    c
)

if n1 == 0 and n2 == 0:
    print(f"  ⚠️ Rien à remplacer dans {target_file}")
    sys.exit(0)

with open(target_file, 'w') as f:
    f.write(c)
print(f"  ✅ {target_file} : déclaration supprimée ({n1}), appel supprimé ({n2})")
PYEOF

# -----------------------------------------------------------------------------
# 3. Hooks inline
# -----------------------------------------------------------------------------
echo ""
echo "=== Hooks inline (susfs_inline_hook_patches.sh) ==="
curl -LSsf "$BASE_JACK/susfs_inline_hook_patches.sh" -o /tmp/susfs_inline_hook_patches.sh || exit 1
chmod +x /tmp/susfs_inline_hook_patches.sh
bash /tmp/susfs_inline_hook_patches.sh || exit 1

# -----------------------------------------------------------------------------
# 3b. Corrections de compatibilité 4.19
# -----------------------------------------------------------------------------
echo ""
echo "=== Corrections de compatibilité 4.19 ==="

# static_call.h
if [ ! -f include/linux/static_call.h ]; then
    cat > include/linux/static_call.h <<'EOF'
#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H
#define static_call(name) (name##_static_call)
#define static_call_cond(name) (name##_static_call)
#define static_call_update(name, func) do { } while (0)
#define static_call_query(name) (name##_static_call)
#endif
EOF
fi

# fdinfo.c
python3 - <<'PYEOF'
import re, sys
path = 'fs/notify/fdinfo.c'
with open(path) as f: c = f.read()
if 'SUSFS_FDINFO_3ARGS_FIX' in c: sys.exit(0)
pattern = r'static\s+void\s+inotify_fdinfo\s*\(\s*struct\s+seq_file\s*\*\s*(\w+)\s*,\s*struct\s+fsnotify_mark\s*\*\s*(\w+)\s*\)'
match = re.search(pattern, c)
if match:
    new_sig = f'static void inotify_fdinfo(struct seq_file *{match.group(1)}, struct fsnotify_mark *{match.group(2)}, struct file *f)'
    c = c[:match.start()] + new_sig + c[match.end():]
    c = '/* SUSFS_FDINFO_3ARGS_FIX */\n' + c
    with open(path, 'w') as f: f.write(c)
PYEOF

# stat.c
python3 - <<'PYEOF'
import re, sys
path = 'fs/stat.c'
with open(path) as f: c = f.read()
if 'SUSFS_STAT_DECLS' in c: sys.exit(0)
includes = '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#include <linux/susfs.h>\n#endif\n'
m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m: c = c[:m[-1].end()] + includes + c[m[-1].end():]
externs = '\n/* SUSFS_STAT_DECLS */\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\nextern bool susfs_is_current_app_uid(void);\nextern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);\nextern void susfs_sus_kstat_spoof_generic_fillattr(struct inode *inode, struct kstat *stat, u32 result_mask);\n#endif\n'
m2 = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m2: c = c[:m2[-1].end()] + externs + c[m2[-1].end():]
defs = '\n#ifndef STATX_SUS_KSTAT\n#define STATX_SUS_KSTAT 0x80000000U\n#endif\n#ifndef STATX_SUS_KSTAT_FUSE\n#define STATX_SUS_KSTAT_FUSE 0x40000000U\n#endif\n'
m3 = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m3: c = c[:m3[-1].end()] + defs + c[m3[-1].end():]
with open(path, 'w') as f: f.write(c)
PYEOF

# cpu_spoof.c
python3 - <<'PYEOF'
import re, sys
path = 'drivers/kernelsu/extension/cpu_spoof.c'
try:
    with open(path) as f: c = f.read()
except FileNotFoundError: sys.exit(0)
if 'CPU_SPOOF_VDSO_FIX' in c: sys.exit(0)
pattern = r'(\s*)(\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)'
match = re.search(pattern, c)
if match:
    new_block = f'\n{match.group(1)}/* CPU_SPOOF_VDSO_FIX */\n{match.group(1)}#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n{match.group(1)}{match.group(2)}\n{match.group(1)}#endif\n'
    c = c[:match.start()] + new_block + c[match.end():]
    with open(path, 'w') as f: f.write(c)
PYEOF

# kpm.c
python3 - <<'PYEOF'
import re, sys
compat = 'drivers/kernelsu/kernel_compat.h'
try:
    with open(compat) as f: c = f.read()
    if 'KSU_ACCESS_OK_FIX' not in c:
        wrapper = '\n/* KSU_ACCESS_OK_FIX */\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)\n#define ksu_access_ok(addr, size) access_ok(VERIFY_READ, addr, size)\n#else\n#define ksu_access_ok(addr, size) access_ok(addr, size)\n#endif\n'
        m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
        c = c[:m[-1].end()] + wrapper + c[m[-1].end():] if m else wrapper + c
        with open(compat, 'w') as f: f.write(c)
except FileNotFoundError: pass
kpm = 'drivers/kernelsu/extension/kpm/kpm.c'
try:
    with open(kpm) as f: c = f.read()
    if 'ksu_access_ok' not in c:
        c = re.sub(r'(?<!ksu_)access_ok\s*\(', 'ksu_access_ok(', c)
        with open(kpm, 'w') as f: f.write(c)
except FileNotFoundError: pass
PYEOF

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
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
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

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ KSU droppé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y' out/.config || { echo "❌ SUSFS droppé"; exit 1; }
echo "✅ config validée"

# -----------------------------------------------------------------------------
# 5. Patchs Motorola
# -----------------------------------------------------------------------------
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
MSM_DRV="techpack/display/msm/msm_drv.c"
if [ -f "$MSM_DRV" ]; then
    printf '\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n' >> "$MSM_DRV"
fi

# -----------------------------------------------------------------------------
# 6. Compilation Kernel
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
echo "✅✅✅ COMPILATION RÉUSSIE ✅✅✅"

mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.58-susfs"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.58-susfs"

# -----------------------------------------------------------------------------
# 7. Compilation ksud (BakaSU)
# -----------------------------------------------------------------------------
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 --branch main https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src"

cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
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

KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

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
rm -rf ./Magisk-v27.0.apk ./lib

cd repack
./magiskboot unpack boot.img
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

if [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
    cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f ./local_su_binary
    echo "✅ ksud + su injectés dans le ramdisk"
fi

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v7.58-boot.img"
cd "$GITHUB_WORKSPACE"

# -----------------------------------------------------------------------------
# 9. Sortie
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ v7.58 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
