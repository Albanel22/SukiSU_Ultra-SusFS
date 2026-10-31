#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.39 : SukiSU-Ultra builtin + SUSFS v2.3.0
#         - Correctif manager detection (ksu_install_fd O_CLOEXEC → 0)
#         - Compilation ksud robuste (libclang-dev + erreurs visibles)
# =============================================================================

echo "=== Build SukiSU-Ultra builtin — V7.39 ==="
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
  device-tree-compiler zip unzip curl git python3 python3-pip cpio patch wget libclang-dev

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
echo "=== Correctif manager detection (ksu_install_fd O_CLOEXEC → 0) ==="
python3 - <<'PYEOF'
import re, sys

path = 'drivers/kernelsu/kernel/supercall/supercall.c'
try:
    with open(path) as f:
        c = f.read()
except FileNotFoundError:
    print("  ⚠️ supercall.c introuvable, skip")
    sys.exit(0)

if 'MSG123' in c:
    print("  ↻ supercall.c : déjà patché, skip")
    sys.exit(0)

# Cible l'appel dans ksu_install_fd()
c2, n1 = re.subn(
    r'(int\s+ksu_install_fd\s*\(\s*void\s*\)\s*\{[^}]*?)return\s+ksu_install_fd_with_permissions\s*\(\s*O_CLOEXEC\s*,\s*0\s*\)',
    r'\1return ksu_install_fd_with_permissions(0, 0); /* MSG123: manager detection fix */',
    c,
    flags=re.DOTALL
)

if n1 == 0:
    print("  ⚠️ ksu_install_fd pattern introuvable dans supercall.c")
    sys.exit(0)

with open(path, 'w') as f:
    f.write(c2)
print(f"  ✅ supercall.c : ksu_install_fd corrigé (O_CLOEXEC → 0)")
PYEOF

# -----------------------------------------------------------------------------
# 2b. Patch SUSFS 4.19
# -----------------------------------------------------------------------------
echo ""
echo "=== Patch SUSFS 4.19 (JackA1ltman) ==="
BASE_JACK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches"

SUSFS_PATCH="/tmp/susfs_patch_to_4.19.patch"
curl -LSsf "$BASE_JACK/Patch/susfs_patch_to_4.19.patch" -o "$SUSFS_PATCH" \
  || { echo "❌ download patch SUSFS échoué"; exit 1; }
[ -s "$SUSFS_PATCH" ] || { echo "❌ patch SUSFS vide"; exit 1; }

if patch -p1 --forward --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    echo "  → Application du patch SUSFS…"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 \
      || { echo "❌ patch SUSFS a échoué"; cat /tmp/susfs_patch.log; exit 1; }
    echo "  ✅ patch SUSFS appliqué"
else
    echo "  ⚠️ Patch SUSFS partiellement rejeté — application puis correction manuelle"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true

    echo "  → Injection des hunks rejetés dans fs/namespace.c…"
    python3 - <<'PYEOF'
import re, sys

path = 'fs/namespace.c'
with open(path) as f:
    c = f.read()

if 'susfs_is_current_ksu_domain' in c:
    print("  ↻ fs/namespace.c : blocs SUSFS déjà présents, skip")
    sys.exit(0)

anchor1 = '#include "internal.h"\n'
if anchor1 not in c:
    print(f"  ❌ anchor1 introuvable : {anchor1!r}")
    sys.exit(1)

bloc1 = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif // #ifdef CONFIG_KSU_SUSFS

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */

#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT

'''
c = c.replace(anchor1, anchor1 + bloc1, 1)

pattern = r'(struct vfsmount \*vfs_kern_mount\([^)]*\)\s*\{.*?if \(!type\)\s*\n\s*return ERR_PTR\(-EINVAL\);\s*\n)'
match = re.search(pattern, c, re.DOTALL)
if not match:
    print("  ❌ vfs_kern_mount pattern introuvable")
    sys.exit(1)

bloc2 = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	// - We will just stop checking for ksu process if /sdcard/Android is accessible,
	//   for the sake of performance
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow;
		}
	}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT

'''
c = c[:match.end()] + bloc2 + c[match.end():]

pattern2 = r'(mnt = alloc_vfsmnt\(name\);\s*\n)'
match2 = re.search(pattern2, c)
if not match2:
    print("  ❌ alloc_vfsmnt pattern introuvable")
    sys.exit(1)

label = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
c = c[:match2.end()] + label + c[match2.end():]

with open(path, 'w') as f:
    f.write(c)
print("  ✅ fs/namespace.c : blocs SUSFS injectés manuellement")
PYEOF

    if ! grep -q "susfs_is_current_ksu_domain" fs/namespace.c; then
        echo "❌ L'injection manuelle dans fs/namespace.c a échoué"
        exit 1
    fi
    echo "  ✅ fs/namespace.c corrigé"
fi

# --- Correction DEFAULT_KSU_MNT_ID ---
echo "  → Ajout de DEFAULT_KSU_MNT_ID…"
python3 - <<'PYEOF'
import sys

path = 'fs/namespace.c'
with open(path) as f:
    c = f.read()

if '#define DEFAULT_KSU_MNT_ID' in c:
    print("  ↻ DEFAULT_KSU_MNT_ID déjà défini")
    sys.exit(0)

if 'DEFAULT_KSU_MNT_ID' in c:
    anchor = '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */'
    if anchor in c:
        c = c.replace(anchor, anchor + '\n#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n', 1)
        with open(path, 'w') as f:
            f.write(c)
        print("  ✅ DEFAULT_KSU_MNT_ID ajouté")
    else:
        c = '#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n' + c
        with open(path, 'w') as f:
            f.write(c)
        print("  ✅ DEFAULT_KSU_MNT_ID ajouté en tête de fichier")
else:
    print("  ↻ DEFAULT_KSU_MNT_ID non utilisé, skip")
PYEOF

# --- Stub linux/static_call.h pour 4.19 ---
echo "  → Création du stub linux/static_call.h pour 4.19…"
if [ ! -f include/linux/static_call.h ]; then
    cat > include/linux/static_call.h <<'EOF'
#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H
/* Stub pour noyaux < 5.10 : les static calls ne sont pas supportées. */
#define static_call(name) (name##_static_call)
#define static_call_cond(name) (name##_static_call)
#define static_call_update(name, func) do { } while (0)
#define static_call_query(name) (name##_static_call)
#endif
EOF
    echo "    ✅ stub créé"
else
    echo "    ↻ stub déjà présent"
fi

find . -name "*.rej" -delete 2>/dev/null || true

for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [ -s "$f" ] || { echo "❌ $f manquant après patch"; exit 1; }
done
echo "  ✅ fichiers SUSFS présents"

if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
    echo "  ✅ susfs.o ajouté à fs/Makefile"
fi

# -----------------------------------------------------------------------------
# 3. Hooks inline
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
# 3b. Corrections de compatibilité
# -----------------------------------------------------------------------------
echo ""
echo "=== Corrections de compatibilité 4.19 ==="

# --- fdinfo.c ---
python3 - <<'PYEOF'
import re, sys
path = 'fs/notify/fdinfo.c'
with open(path) as f:
    c = f.read()
if 'SUSFS_FDINFO_3ARGS_FIX' in c:
    print("  ↻ fs/notify/fdinfo.c : déjà corrigé"); sys.exit(0)
pattern = r'static\s+void\s+inotify_fdinfo\s*\(\s*struct\s+seq_file\s*\*\s*(\w+)\s*,\s*struct\s+fsnotify_mark\s*\*\s*(\w+)\s*\)'
match = re.search(pattern, c)
if not match:
    print("  ⚠️ inotify_fdinfo pattern introuvable"); sys.exit(0)
m_name, mark_name = match.group(1), match.group(2)
new_sig = f'static void inotify_fdinfo(struct seq_file *{m_name}, struct fsnotify_mark *{mark_name}, struct file *f)'
c = c[:match.start()] + new_sig + c[match.end():]
c = '/* SUSFS_FDINFO_3ARGS_FIX : inotify_fdinfo accepte 3 args pour show_fdinfo */\n' + c
with open(path, 'w') as f:
    f.write(c)
print("  ✅ fs/notify/fdinfo.c : inotify_fdinfo corrigée (3 args)")
PYEOF

# --- cpu_spoof.c ---
python3 - <<'PYEOF'
import re, sys
path = 'drivers/kernelsu/extension/cpu_spoof.c'
try:
    with open(path) as f: c = f.read()
except FileNotFoundError:
    print("  ⚠️ cpu_spoof.c introuvable"); sys.exit(0)
if 'CPU_SPOOF_VDSO_FIX' in c:
    print("  ↻ cpu_spoof.c : déjà corrigé"); sys.exit(0)
pattern = r'(\s*)(\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)'
match = re.search(pattern, c)
if not match:
    print("  ⚠️ vdso_clock_mode pattern introuvable"); sys.exit(0)
indent, stmt = match.group(1), match.group(2)
new_block = f'''
{indent}/* CPU_SPOOF_VDSO_FIX : vdso_clock_mode n'existe pas sur 4.19 */
{indent}#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
{indent}{stmt}
{indent}#endif
'''
c = c[:match.start()] + new_block + c[match.end():]
with open(path, 'w') as f: f.write(c)
print("  ✅ cpu_spoof.c : vdso_clock_mode protégé")
PYEOF

# --- kpm.c ---
python3 - <<'PYEOF'
import re, sys
compat_path = 'drivers/kernelsu/kernel_compat.h'
try:
    with open(compat_path) as f: compat = f.read()
except FileNotFoundError:
    print("  ⚠️ kernel_compat.h introuvable"); sys.exit(0)
if 'KSU_ACCESS_OK_FIX' not in compat:
    wrapper = '''
/* KSU_ACCESS_OK_FIX : access_ok sur 4.19 ARM64 attend 3 args */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define ksu_access_ok(addr, size) access_ok(VERIFY_READ, addr, size)
#else
#define ksu_access_ok(addr, size) access_ok(addr, size)
#endif
'''
    includes = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', compat))
    if includes:
        compat = compat[:includes[-1].end()] + wrapper + compat[includes[-1].end():]
    else:
        compat = wrapper + compat
    with open(compat_path, 'w') as f: f.write(compat)
    print("  ✅ kernel_compat.h : ksu_access_ok ajouté")
kpm_path = 'drivers/kernelsu/extension/kpm/kpm.c'
try:
    with open(kpm_path) as f: kpm = f.read()
except FileNotFoundError:
    print("  ⚠️ kpm.c introuvable"); sys.exit(0)
if 'ksu_access_ok' not in kpm:
    kpm = re.sub(r'(?<!ksu_)access_ok\s*\(', 'ksu_access_ok(', kpm)
    with open(kpm_path, 'w') as f: f.write(kpm)
    print("  ✅ kpm.c : access_ok → ksu_access_ok")
else:
    print("  ↻ kpm.c : déjà corrigé")
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
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  vendor/lito-perf_defconfig

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

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  olddefconfig 2>&1 | tail -3

# --- VÉRIFICATION STRICTE CONFIG_KSU ---
echo "  → Vérification CONFIG_KSU dans .config final…"
if ! grep -q '^CONFIG_KSU=y' out/.config; then
    echo "❌ CONFIG_KSU n'est pas 'y' dans out/.config !"
    echo "   Lignes CONFIG_KSU trouvées :"
    grep 'CONFIG_KSU' out/.config || echo "   (aucune)"
    exit 1
fi
echo "  ✅ CONFIG_KSU=y confirmé"

for opt in CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_KSTAT; do
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
echo "✅✅✅ COMPILATION RÉUSSIE (V7.39) ✅✅✅"

# -----------------------------------------------------------------------------
# 6b. VÉRIFICATION STRICTE DES SYMBOLES KSU DANS LE NOYAU
# -----------------------------------------------------------------------------
echo ""
echo "=== Vérification des symboles ksu_handle_* dans System.map ==="
if [ ! -f out/System.map ]; then
    echo "❌ out/System.map absent"
    exit 1
fi
KSU_SYMS=$(grep -E 'ksu_handle_execveat|ksu_handle_stat|ksu_handle_faccessat|ksu_handle_vfs_read' out/System.map || true)
if [ -z "$KSU_SYMS" ]; then
    echo "❌ Aucun symbole ksu_handle_* trouvé dans System.map"
    exit 1
fi
echo "✅ Symboles KSU trouvés :"
echo "$KSU_SYMS" | head -10

# -----------------------------------------------------------------------------
# 7. Sauvegarde
# -----------------------------------------------------------------------------
mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.39-susfs"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.39-susfs"

# -----------------------------------------------------------------------------
# 7b. Compilation ksud (avec affichage des erreurs)
# -----------------------------------------------------------------------------
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly 2>&1 | tail -3 || true
source "$HOME/.cargo/env" || true
[ -x "$HOME/.cargo/bin/cargo" ] || { echo "❌ cargo absent"; exit 1; }

rustc --version
rustup update nightly 2>&1 | tail -3 || true
rustup target add aarch64-linux-android 2>&1 | tail -2 || true

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip || true
unzip -q android-ndk-r26d-linux.zip || true
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 --branch builtin https://github.com/ShirkNeko/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src"

KSUD_DIR=$(find "$GITHUB_WORKSPACE/ksud-src" -name 'Cargo.toml' -type f 2>/dev/null | while read cargo; do
    if grep -qE 'name\s*=\s*"ksud"' "$cargo" 2>/dev/null; then dirname "$cargo"; break; fi
done | head -1)

if [ -z "$KSUD_DIR" ]; then
    echo "❌ Cargo.toml de ksud introuvable"
    exit 1
fi

(
    cd "$KSUD_DIR"
    mkdir -p .cargo
    cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
EOF
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    echo "→ cargo build (affichage complet des erreurs)…"
    cargo build --release --target aarch64-linux-android 2>&1 | tail -40
) || {
    echo "❌ cargo build a échoué — voir les erreurs ci-dessus"
    exit 1
}

KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
if [ -z "$KSUD_BINARY" ]; then
    echo "❌ ksud introuvable après cargo build"
    exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
KSUD_OK=1
echo "✅ ksud compilé"

cd "$GITHUB_WORKSPACE"

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

# Injection de ksud dans le ramdisk
if [ "${KSUD_OK:-0}" = "1" ] && [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
    cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f ./local_su_binary
    echo "✅ ksud + su injectés dans le ramdisk"
else
    echo "⚠️ Repack SANS ksud — le manager ne détectera probablement pas le noyau"
fi

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v7.39-boot.img"
cd "$GITHUB_WORKSPACE"
echo "✅ boot.img repacké"

# -----------------------------------------------------------------------------
# 9. Sortie
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ v7.39 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
