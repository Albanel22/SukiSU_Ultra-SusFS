#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.60-dev : BRANCHE D'ESSAI "SuSFS complet" (base = V7.59 qui fonctionne)
#   Objectif : récupérer les blocs du patch SuSFS rejetés + activer SUS_MOUNT / OPEN_REDIRECT
#   NE PAS flasher directement : tester avec "fastboot boot" d'abord.
#   Base : SukiSU-Ultra + SuSFS (patch Jack) + ksud épinglé sur le commit du driver
#   Changements vs V7.58 :
#   - dernière ligne corrigée (guillemet non fermé -> exit 2)
#   - ksud compilé au MÊME commit que le driver du noyau
#   - validation stricte des options SuSFS après olddefconfig
#   - audits (hooks, setuid/seccomp, reboot, symboles SuSFS) écrits dans
#     output/audit-v7.59.txt  (aucun effet sur le build)
# =============================================================================

echo "=== Build SukiSU-Ultra — V7.60-dev (SuSFS complet) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
VER="v7.60-dev"

# Fonctions SuSFS supplémentaires à essayer (1 = activer, 0 = désactiver)
SUSFS_SUS_MOUNT="${SUSFS_SUS_MOUNT:-1}"
SUSFS_OPEN_REDIRECT="${SUSFS_OPEN_REDIRECT:-1}"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
: > "$AUDIT"

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
# La branche lineage-23.2 évolue : on fige la source sur le commit qui a donné un build valide.
# Vide = dernière version de la branche (peut casser, voir README).
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
if [ -n "$KERNEL_PIN" ]; then
    git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
    cd kernel_sources
    echo "Tête actuelle de lineage-23.2 : $(git log --oneline -1 origin/lineage-23.2)" | tee -a "$AUDIT"
    if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
        echo "⚠️ $KERNEL_PIN absent de lineage-23.2, recherche dans les autres branches..." | tee -a "$AUDIT"
        git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
        git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable dans le dépôt"; exit 1; }
    fi
    echo "Source figée sur : $KERNEL_PIN" | tee -a "$AUDIT"
else
    git clone "$KERNEL_URL" -b lineage-23.2 --depth=1 kernel_sources
    cd kernel_sources
fi
git log --oneline -1 | tee -a "$AUDIT"
echo "SHA complet de la source : $(git rev-parse HEAD)" | tee -a "$AUDIT"

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

# Option : figer le driver sur un commit précis (test A/B). Vide = dernier commit.
# Exemple : SUKI_PIN="${SUKI_PIN:-b5917072}"
SUKI_PIN="${SUKI_PIN:-b5917072}"
if [ -n "$SUKI_PIN" ] && [ -e KernelSU/.git ]; then
    git -C KernelSU fetch --unshallow 2>/dev/null || git -C KernelSU fetch --all --tags 2>/dev/null || true
    if git -C KernelSU checkout "$SUKI_PIN" 2>/dev/null; then
        echo "✅ driver figé sur $SUKI_PIN"
    else
        echo "⚠️ checkout $SUKI_PIN impossible, driver laissé au dernier commit"
    fi
fi

# Commit exact du driver (pour compiler ksud à la même révision)
SUKI_REV=""
if [ -d KernelSU/.git ] || [ -f KernelSU/.git ]; then
    SUKI_REV=$(git -C KernelSU rev-parse HEAD 2>/dev/null || true)
fi
echo "SukiSU driver rev: ${SUKI_REV:-inconnu}"
echo "SukiSU driver rev: ${SUKI_REV:-inconnu}" >> "$AUDIT"

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

echo ""
echo "=== Blocs rejetés du patch SuSFS : nouvelle tentative avec fuzz ==="
mkdir -p "$GITHUB_WORKSPACE/output/rejects-initiaux" "$GITHUB_WORKSPACE/output/rejects-restants"
find . -name "*.rej" -exec cp --parents {} "$GITHUB_WORKSPACE/output/rejects-initiaux/" \; 2>/dev/null || true
mapfile -t REJS < <(find . -name "*.rej" | sort)
echo "${#REJS[@]} fichier(s) .rej à retraiter"
for rej in "${REJS[@]}"; do
    base="${rej%.rej}"
    if patch -F3 --forward --no-backup-if-mismatch "$base" < "$rej" > /tmp/retry.log 2>&1; then
        echo "  ✅ $base : blocs appliqués avec fuzz"
        rm -f "$rej"
    else
        echo "  ⚠️ $base : échec persistant"
        tail -6 /tmp/retry.log
    fi
done
find . -name "*.rej" -exec cp --parents {} "$GITHUB_WORKSPACE/output/rejects-restants/" \; 2>/dev/null || true
echo "reste après retry : $(find . -name '*.rej' | wc -l) fichier(s) .rej"
find . -name "*.rej" -delete 2>/dev/null || true
find . -name "*.orig" -delete 2>/dev/null || true

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
import sys, os
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
hdr = ''
if os.path.exists('include/linux/susfs_def.h'):
    with open('include/linux/susfs_def.h') as hf: hdr = hf.read()
if '#define DEFAULT_KSU_MNT_ID' in hdr:
    # susfs_def.h définit déjà ces macros : on retire les doublons éventuels de namespace.c
    # (un bloc du patch, appliqué avec fuzz, les redéfinit avec d'autres valeurs)
    import re
    n_total = 0
    for name in ('DEFAULT_KSU_MNT_ID', 'DEFAULT_KSU_MNT_GROUP_ID'):
        if re.search(r'#define\s+' + name + r'\b', hdr):
            c, n = re.subn(r'^[ \t]*#define[ \t]+' + name + r'\b[^\n]*\n', '', c, flags=re.M)
            n_total += n
    if n_total:
        with open(path, 'w') as f: f.write(c)
    print(f"  ↻ macros KSU_MNT déjà définies par susfs_def.h : {n_total} doublon(s) retiré(s) de namespace.c")
    sys.exit(0)
try:
    hdr = open('include/linux/susfs_def.h').read()
except FileNotFoundError:
    hdr = ''
if '#define DEFAULT_KSU_MNT_ID' not in c and '#define DEFAULT_KSU_MNT_ID' not in hdr and 'DEFAULT_KSU_MNT_ID' in c:
    anchor = '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */'
    c = c.replace(anchor, anchor + '\n#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n', 1) if anchor in c else '#define DEFAULT_KSU_MNT_ID 500000\n' + c
    with open(path, 'w') as f: f.write(c)
PYEOF

find . -name "*.rej" -delete 2>/dev/null || true
if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi

# -----------------------------------------------------------------------------
# 2c. FIX PROPRE : Suppression de la déclaration ET de l'appel
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
# 3c. Fallback détection manager (ne dépend plus des SID zygote en mode SuSFS)
#     Hypothèse à tester : susfs_zygote_sid reste à 0 -> le manager ne reçoit
#     ni disable_seccomp() ni ksu_install_fd(). MANAGER_FALLBACK=0 pour désactiver.
# -----------------------------------------------------------------------------
MANAGER_FALLBACK="${MANAGER_FALLBACK:-1}"
if [ "$MANAGER_FALLBACK" = "1" ]; then
echo ""
echo "=== Fallback détection manager (lsm_hook.c) ==="
python3 - <<'PYEOF'
import re, sys
path = 'drivers/kernelsu/hook/lsm_hook.c'
try:
    with open(path) as f: c = f.read()
except FileNotFoundError:
    print("  ⚠️ lsm_hook.c introuvable, skip")
    sys.exit(0)
if 'MGR_FALLBACK' in c:
    print("  ↻ déjà patché")
    sys.exit(0)
pattern = (r'int\s+ksu_handle_setresuid\s*\(\s*uid_t\s+ruid\s*,\s*uid_t\s+euid\s*,\s*uid_t\s+suid\s*\)\s*\{'
           r'\s*uid_t\s+cur_uid\s*=\s*current_uid\(\)\.val;\s*if\s*\(\s*cur_uid\s*!=\s*0\s*\)\s*return\s+0;')
m = re.search(pattern, c)
if not m:
    print("  ⚠️ motif ksu_handle_setresuid introuvable, skip")
    sys.exit(0)
block = '''

    /* MGR_FALLBACK : manager reconnu sans dependre des SID zygote */
    if (likely(ksu_is_manager_appid_valid()) && unlikely(is_uid_manager(ruid))) {
        disable_seccomp();
        pr_info("install fd for manager (fallback): %d\\n", ruid);
        ksu_install_fd();
        return 0;
    }
'''
c = c[:m.end()] + block + c[m.end():]
with open(path, 'w') as f: f.write(c)
print("  ✅ fallback manager injecté dans ksu_handle_setresuid")
PYEOF
grep -n "MGR_FALLBACK" drivers/kernelsu/hook/lsm_hook.c || echo "  ⚠️ fallback non appliqué"
fi

# -----------------------------------------------------------------------------
# 4. Config
# -----------------------------------------------------------------------------
echo ""
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# --- Compatibilité clang : le noyau peut passer des -Wno-... inconnus d'un clang ancien
CLANG_MAJOR=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
echo "clang : $(command -v clang) -> $(readlink -f "$(command -v clang)")" | tee -a "$AUDIT"
clang --version | head -2 | tee -a "$AUDIT"
echo "clang version majeure : ${CLANG_MAJOR:-inconnue}" | tee -a "$AUDIT"
CC_ARGS=""
if [ "${FORCE_CLANG_WRAP:-1}" = "1" ] || [ "${CLANG_MAJOR:-99}" -lt 16 ]; then
    cat > "$GITHUB_WORKSPACE/clang-wrap" <<'WRAPEOF'
#!/bin/bash
args=()
for a in "$@"; do
    case "$a" in
        -Wno-cast-function-type-strict|-Wcast-function-type-strict) ;;
        *) args+=("$a") ;;
    esac
done
exec clang -Wno-unknown-warning-option "${args[@]}" -Wno-unknown-warning-option
WRAPEOF
    chmod +x "$GITHUB_WORKSPACE/clang-wrap"
    CC_ARGS="CC=$GITHUB_WORKSPACE/clang-wrap"
    echo "⚠️ clang < 16 : wrapper actif (flags inconnus ignorés)" | tee -a "$AUDIT"
fi

mkdir -p out
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

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

if [ "$SUSFS_SUS_MOUNT" = "1" ]; then
    sed -i 's/^# CONFIG_KSU_SUSFS_SUS_MOUNT is not set/CONFIG_KSU_SUSFS_SUS_MOUNT=y/' out/.config
fi
if [ "$SUSFS_OPEN_REDIRECT" = "1" ]; then
    sed -i 's/^# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set/CONFIG_KSU_SUSFS_OPEN_REDIRECT=y/' out/.config
fi

make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ KSU droppé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y' out/.config || { echo "❌ SUSFS droppé"; exit 1; }

# Validation stricte des sous-options SuSFS (échec si olddefconfig les a supprimées)
SUSFS_MISSING=0
for o in KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SUS_MAP; do
    if grep -q "^CONFIG_${o}=y" out/.config; then
        echo "  ✅ CONFIG_${o}"
    else
        echo "  ❌ CONFIG_${o} absent après olddefconfig"
        SUSFS_MISSING=1
    fi
done
[ "$SUSFS_MISSING" -eq 0 ] || { echo "❌ Options SuSFS perdues (voir Kconfig du driver)"; exit 1; }
for o in KSU_SUSFS_SUS_MOUNT KSU_SUSFS_OPEN_REDIRECT; do
    if grep -q "^CONFIG_${o}=y" out/.config; then
        echo "  ✅ CONFIG_${o} actif"
    else
        echo "  ℹ️ CONFIG_${o} inactif"
    fi
done
echo "✅ config validée"

# -----------------------------------------------------------------------------
# 4b. AUDITS (diagnostic uniquement, écrits dans output/audit-v7.59.txt)
# -----------------------------------------------------------------------------
{
    echo ""
    echo "=== AUDIT HOOKS (lignes réelles, pas seulement la présence du nom) ==="
    for h in "ksu_handle_sys_reboot kernel/reboot.c" \
             "ksu_handle_execveat fs/exec.c" \
             "ksu_handle_faccessat fs/open.c" \
             "ksu_handle_stat fs/stat.c" \
             "ksu_handle_setresuid kernel/sys.c" \
             "ksu_handle_sys_read fs/read_write.c" \
             "ksu_handle_input_handle_event drivers/input/input.c"; do
        set -- $h
        echo "--- $1 dans $2"
        grep -n "$1" "$2" || echo "❌ ABSENT"
    done

    echo ""
    echo "=== DUMP REBOOT HOOK ==="
    grep -n "ksu_handle_sys_reboot" kernel/reboot.c || true
    sed -n '/SYSCALL_DEFINE4(reboot/,/^}/p' kernel/reboot.c | head -20 || true

    echo ""
    echo "=== SETUID HOOK (kernel/sys.c) ==="
    grep -n -B2 -A10 "ksu_handle_setresuid\|ksu_handle_setuid" kernel/sys.c | head -80 || true

    echo ""
    echo "=== DRIVER : seccomp / install fd / setuid ==="
    grep -rn "disable_seccomp\|ksu_install_fd\|ksu_handle_setuid\|ksu_handle_setresuid" drivers/kernelsu | head -40 || true

    echo ""
    echo "=== SUPERCALL : #if / #else / #endif ==="
    grep -n "^#if\|^#else\|^#endif" drivers/kernelsu/supercall/supercall.c | head -40 || true
    sed -n '125,160p' drivers/kernelsu/supercall/supercall.c || true
    echo "--- dispatch.c autour de ksu_handle_sys_reboot"
    sed -n '405,450p' drivers/kernelsu/supercall/dispatch.c || true

    echo ""
    echo "=== CONFIG KSU / SECCOMP / KPROBES ==="
    grep -E "KSU|KPROBES|SECCOMP" out/.config || true

    echo ""
    echo "=== LSM_HOOK : détection manager / setresuid / seccomp ==="
    sed -n '15,185p' drivers/kernelsu/hook/lsm_hook.c || true

    echo ""
    echo "=== DISPATCH : suite de ksu_handle_sys_reboot (variante SuSFS) ==="
    sed -n '450,560p' drivers/kernelsu/supercall/dispatch.c || true

    echo ""
    echo "=== disable_seccomp (app_profile.c) ==="
    sed -n '50,80p' drivers/kernelsu/policy/app_profile.c || true

    echo ""
    echo "=== SID zygote (chemin setresuid en mode SuSFS) ==="
    grep -rn "susfs_zygote_sid\|susfs_zygote_next_sid" fs include/linux drivers/kernelsu security 2>/dev/null | head -40 || true
    echo "--- susfs_is_sid_equal"
    grep -rn "susfs_is_sid_equal" fs include/linux drivers/kernelsu 2>/dev/null | head -10 || true
    echo "--- selinux.c : initialisation des SID (lignes 250-345)"
    sed -n '250,345p' drivers/kernelsu/selinux/selinux.c || true
    echo "--- appelants de l'init des SID"
    grep -rn "KERNEL_ZYGOTE_DOMAIN\|susfs_set_sid\|susfs_init_sids\|setup_selinux\|cache_sid" drivers/kernelsu | head -30 || true
    echo "--- ksud.c autour de track_throne"
    sed -n '70,125p' drivers/kernelsu/runtime/ksud.c || true
    echo "--- pkg_observer.c"
    sed -n '1,80p' drivers/kernelsu/manager/pkg_observer.c || true
    echo "--- selinux.c : cache_sid (lignes 125-165)"
    sed -n '125,165p' drivers/kernelsu/selinux/selinux.c || true
    echo "--- appelants de susfs_set_batch_sid"
    grep -rn "susfs_set_batch_sid" drivers/kernelsu fs include 2>/dev/null | head -10 || true
    echo "--- ksud.c autour des cache_sid (195-215 et 283-335)"
    sed -n '195,215p;283,335p' drivers/kernelsu/runtime/ksud.c || true

    echo ""
    echo "=== Enregistrement du manager (appid / throne tracker) ==="
    grep -rn "ksu_is_manager_appid_valid\|ksu_set_manager_appid\|ksu_manager_appid" drivers/kernelsu | head -30 || true
    grep -rn "track_throne" drivers/kernelsu | head -20 || true

    echo ""
    echo "=== Makefile du driver (lsm_hook compilé ?) ==="
    ls drivers/kernelsu || true
    grep -rn "lsm_hook\|hook/" drivers/kernelsu --include=Makefile --include=Kbuild --include=*.mk | head -20 || true

    echo ""
    echo "=== Kconfig du driver (symboles SuSFS / hook) ==="
    grep -rn "config KSU" drivers/kernelsu/Kconfig | head -40 || true

    echo ""
    echo "=== MAGIC ==="
    grep -rn "KSU_INSTALL_MAGIC1\|ksu_handle_sys_reboot" drivers/kernelsu | head -10 || true

    echo ""
    echo "=== SuSFS : fichiers et patch ==="
    ls -l fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h 2>&1 || true
    grep -n susfs fs/Makefile || echo "⚠️ susfs.o absent de fs/Makefile"
    grep -E "FAILED|rejected|Hunk" /tmp/susfs_patch.log | head -30 || true
    true
} 2>&1 | tee -a "$AUDIT"

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
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|undefined reference|fatal error:" build.log | head -30 || true
    {
        echo "=== ERREURS (rc=$MAKE_RC) ==="
        grep -nE "error:|undefined symbol|undefined reference|fatal error:|\*\*\*" build.log | head -120 || true
        echo ""
        echo "=== 150 DERNIÈRES LIGNES ==="
        tail -n 150 build.log
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅✅✅ COMPILATION RÉUSSIE ✅✅✅"

cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}-susfs"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-${VER}-susfs"

{
    echo ""
    echo "=== AUDIT SYMBOLES SuSFS dans System.map ==="
    echo "nombre de symboles susfs_ : $(grep -ci ' susfs_' out/System.map || true)"
    grep -i ' susfs_' out/System.map | head -25 || true
    echo "ksu_handle_sys_reboot : $(grep -c ' ksu_handle_sys_reboot' out/System.map || true)"
    grep -E " (ksu_handle_setresuid|disable_seccomp|ksu_install_fd|ksu_handle_execveat)$" out/System.map || echo "⚠️ symboles hook absents du System.map"
    true
} 2>&1 | tee -a "$AUDIT"

# -----------------------------------------------------------------------------
# 7. Compilation ksud (même révision que le driver)
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
git clone --branch main https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src"
if [ -n "$SUKI_REV" ]; then
    if git -C "$GITHUB_WORKSPACE/ksud-src" checkout "$SUKI_REV" 2>/dev/null; then
        echo "✅ ksud épinglé sur $SUKI_REV"
    else
        echo "⚠️ checkout $SUKI_REV impossible, ksud construit depuis main"
    fi
fi
git -C "$GITHUB_WORKSPACE/ksud-src" log --oneline -1 | tee -a "$AUDIT"

# Le dossier du crate ksud peut changer d'un commit à l'autre : on le cherche
find_ksud_dir() {
    grep -rl --include=Cargo.toml '^name *= *"ksud"' "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null \
        | grep -v '/target/' | head -1 | xargs -r dirname
}
KSUD_DIR=$(find_ksud_dir || true)
if [ -z "$KSUD_DIR" ]; then
    echo "⚠️ crate ksud absent à la révision épinglée, bascule sur main"
    git -C "$GITHUB_WORKSPACE/ksud-src" checkout main
    git -C "$GITHUB_WORKSPACE/ksud-src" log --oneline -1 | tee -a "$AUDIT"
    KSUD_DIR=$(find_ksud_dir || true)
fi
if [ -z "$KSUD_DIR" ]; then
    echo "❌ crate ksud introuvable"
    ls -la "$GITHUB_WORKSPACE/ksud-src" "$GITHUB_WORKSPACE/ksud-src/userspace" 2>&1 || true
    exit 1
fi
echo "ksud dir: $KSUD_DIR" | tee -a "$AUDIT"

cd "$KSUD_DIR"
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
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-${VER}-boot.img"
cd "$GITHUB_WORKSPACE"

# -----------------------------------------------------------------------------
# 9. Sortie
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh "$GITHUB_WORKSPACE/output/"
