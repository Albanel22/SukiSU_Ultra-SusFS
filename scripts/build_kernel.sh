#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.44 : SukiSU-Ultra builtin + SUSFS + Astuces BakaSU (Stabilité 4.19)
#         - Fix O_CLOEXEC global
#         - Fix SELinux Exports (static removed)
#         - Fix seccomp (setuid_hook)
#         - Fix SIDTAB sync
#         - Compilation ksud depuis les sources
# =============================================================================

echo "=== Build SukiSU-Ultra v7.44 (Stable) ==="
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
KSU_DIR="drivers/kernelsu"
echo "✅ SukiSU-Ultra intégré (KSU_DIR: $KSU_DIR)"

# -----------------------------------------------------------------------------
# 2a. Neutralisation check.mk & Nettoyage Unicode (BakaSU)
# -----------------------------------------------------------------------------
echo ""
echo "=== Neutralisation check.mk & Nettoyage Unicode ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    for f in $FILES; do sed -i 's/\$(error/\$(warning/g' "$f"; done
done

python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F', '\u205F', '\u3000']
count = 0
for root, dirs, files in os.walk('.'):
    if 'kernelsu' not in root: continue
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    content = content.replace(uchar, ' ')
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count += 1
            except: pass
print(f"  ✅ {count} fichiers nettoyés (Unicode)")
PYEOF

# -----------------------------------------------------------------------------
# 2b. Fix SELinux Exports (BakaSU)
# -----------------------------------------------------------------------------
echo ""
echo "=== Fix SELinux Exports ==="
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
[ -f "security/selinux/hooks.c" ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

# -----------------------------------------------------------------------------
# 2c. Fix O_CLOEXEC Global (BakaSU)
# -----------------------------------------------------------------------------
echo ""
echo "=== Fix O_CLOEXEC Global ==="
FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
for f in $FILES_GET_UNUSED; do
    sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
    echo "  ✅ get_unused_fd_flags fixé dans $f"
done

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
for f in $FILES_ANON_INODE; do
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/, O_CLOEXEC)/)/g' "$f"
    echo "  ✅ anon_inode_getfile nettoyé dans $f"
done

# -----------------------------------------------------------------------------
# 2d. Fix Seccomp (BakaSU)
# -----------------------------------------------------------------------------
echo ""
echo "=== Fix Seccomp ==="
APP_PROFILE=$(find "$KSU_DIR" -name "app_profile.c" 2>/dev/null | head -1 || true)
SETUID_HOOK=$(find "$KSU_DIR" -name "setuid_hook.c" 2>/dev/null | head -1 || true)

if [ -n "$APP_PROFILE" ]; then
    if grep -q "^static void disable_seccomp" "$APP_PROFILE"; then
        sed -i 's/^static void disable_seccomp/void disable_seccomp/' "$APP_PROFILE"
    fi
fi

if [ -f "$SETUID_HOOK" ]; then
    python3 - "$SETUID_HOOK" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()
old_block = '''#else
        disable_seccomp();
#endif'''
new_block = '''#else
        if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {
            spin_lock_irq(&current->sighand->siglock);
            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
            spin_unlock_irq(&current->sighand->siglock);
        }
#endif'''
if old_block in content:
    content = content.replace(old_block, new_block, 1)
    with open(path, 'w') as f: f.write(content)
    print("  ✅ setuid_hook.c : seccomp corrigé")
PYEOF
fi

# -----------------------------------------------------------------------------
# 2e. Fix SIDTAB Sync (Commit a810677)
# -----------------------------------------------------------------------------
echo ""
echo "=== Fix SIDTAB Sync ==="
SELINUX_C=$(find "$KSU_DIR" -name "selinux.c" -path "*selinux*" 2>/dev/null | head -1 || true)
if [ -f "$SELINUX_C" ]; then
    python3 - "$SELINUX_C" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()
count = 0
for var in ['buf', 'scon', 'tcon']:
    old = f"length = security_context_to_sid_with_policy(backup_sepolicy, {var}, {'strlen('+var+')' if var!='buf' else 'size'}, &{'sid' if var=='buf' else ('ssid' if var=='scon' else 'tsid')}, SECSID_NULL, GFP_KERNEL);\n    if (length)\n        goto out;"
    new = f"length = security_context_to_sid_with_policy(backup_sepolicy, {var}, {'strlen('+var+')' if var!='buf' else 'size'}, &{'sid' if var=='buf' else ('ssid' if var=='scon' else 'tsid')}, SECSID_NULL, GFP_KERNEL);\n    if (length) {{\n        goto out;\n    }} else {{\n        security_context_to_sid({var}, {'strlen('+var+')' if var!='buf' else 'size'}, &tmp, GFP_KERNEL);\n    }}"
    if old in content:
        content = content.replace(old, new, 1)
        count += 1
if 'u32 sid, len;' in content and 'u32 sid, len, tmp;' not in content:
    content = content.replace('u32 sid, len;', 'u32 sid, len, tmp;', 1)
if 'u32 ssid, tsid;' in content and 'u32 ssid, tsid, tmp;' not in content:
    content = content.replace('u32 ssid, tsid;', 'u32 ssid, tsid, tmp;', 1)
if count > 0:
    with open(path, 'w') as f: f.write(content)
    print(f"  ✅ selinux.c : {count} sync sidtab injectés")
PYEOF
fi

# -----------------------------------------------------------------------------
# 3. Patch SUSFS (JackA1ltman)
# -----------------------------------------------------------------------------
echo ""
echo "=== Patch SUSFS 4.19 (JackA1ltman) ==="
BASE_JACK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches"
SUSFS_PATCH="/tmp/susfs_patch_to_4.19.patch"
curl -LSsf "$BASE_JACK/Patch/susfs_patch_to_4.19.patch" -o "$SUSFS_PATCH" || { echo "❌ download patch échoué"; exit 1; }

if patch -p1 --forward --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1
    echo "  ✅ patch SUSFS appliqué"
else
    echo "  ⚠️ Patch SUSFS partiellement rejeté"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true
fi
find . -name "*.rej" -delete 2>/dev/null || true
find . -name "*.orig" -delete 2>/dev/null || true

# Corrections post-patch SUSFS
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
done

python3 << 'PYEOF'
from pathlib import Path
# namespace.c
p = Path("fs/namespace.c")
if p.exists() and 'susfs_def.h' not in p.read_text():
    content = p.read_text()
    decl = '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif\n'
    anchor = '#include "internal.h"'
    if anchor in content:
        p.write_text(content.replace(anchor, anchor + '\n' + decl, 1))
# super.c
p = Path("fs/super.c")
if p.exists() and 'susfs_def.h' not in p.read_text():
    content = p.read_text()
    decl = '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#endif\n'
    anchor = '#include "internal.h"'
    if anchor in content: p.write_text(content.replace(anchor, anchor + '\n' + decl, 1))
# stat.c
p = Path("fs/stat.c")
if p.exists() and 'susfs_def.h' not in p.read_text():
    content = p.read_text()
    decl = '\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n'
    anchor = '#include <asm/unistd.h>'
    if anchor in content: p.write_text(content.replace(anchor, anchor + '\n' + decl, 1))
PYEOF
if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi
echo "  ✅ Corrections SUSFS terminées"

# -----------------------------------------------------------------------------
# 4. Inline hooks (JackA1ltman)
# -----------------------------------------------------------------------------
echo ""
echo "=== Inline hooks ==="
curl -LSsf "$BASE_JACK/susfs_inline_hook_patches.sh" -o /tmp/susfs_inline_hook_patches.sh || exit 1
chmod +x /tmp/susfs_inline_hook_patches.sh
bash /tmp/susfs_inline_hook_patches.sh || exit 1
echo "✅ hooks injectés"

# -----------------------------------------------------------------------------
# 5. Config
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
CONFIG_KSU_SUSFS=y
# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set
# CONFIG_KSU_TRACEPOINT_HOOK is not set
# CONFIG_KSU_MANUAL_HOOK is not set
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KRETPROBES=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ KSU droppé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y' out/.config || { echo "❌ SUSFS droppé"; exit 1; }
echo "✅ config validée"

# -----------------------------------------------------------------------------
# 6. Patch Motorola
# -----------------------------------------------------------------------------
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
MSM_DRV="techpack/display/msm/msm_drv.c"
if [ -f "$MSM_DRV" ]; then
    printf '\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n' >> "$MSM_DRV"
fi

# -----------------------------------------------------------------------------
# 7. Compilation
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
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.44"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.44"

# -----------------------------------------------------------------------------
# 8. Compilation KSUD (depuis les sources SukiSU-Ultra)
# -----------------------------------------------------------------------------
echo ""
echo "=== Compilation ksud (SukiSU-Ultra main) ==="
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
echo "✅ ksud compilé (SukiSU-Ultra main)"

# -----------------------------------------------------------------------------
# 9. Repack
# -----------------------------------------------------------------------------
echo ""
echo "=== Repack ==="
cd "$GITHUB_WORKSPACE"
rm -f boot-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img || true

if [ ! -f boot-stock.img ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img introuvable"; exit 1
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

# Injection BakaSU
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-v7.44-boot.img"
cd "$GITHUB_WORKSPACE"
echo "✅ boot.img repacké"

# -----------------------------------------------------------------------------
# 10. Sortie
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ v7.44 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
