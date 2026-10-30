#!/bin/bash
set -euo pipefail

# =============================================================================
# V11.4 : SukiSU-Ultra (builtin) + SUSFS v2.3.0 (Patch fourni) + Manual Hooks
#         Base V11.3 (ident. V11.2 + §4b manual hooks)
#         Mini-patch config : ENABLE_LOG syntaxe Kconfig + désactivations
#                             complètes + vérifications durcies
# =============================================================================

echo "=== Build SukiSU-Ultra + SUSFS v2.3.0 + Manual Hooks — V11.4 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev patch

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION SukiSU-Ultra (builtin) ====================
echo "=== Intégration SukiSU-Ultra (builtin) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true
curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
[ ! -d "drivers/kernelsu" ] && echo "❌ Échec de l'intégration SukiSU" && exit 1
echo "✅ SukiSU-Ultra (builtin) intégré"

# ==================== 3. APPLICATION DU PATCH SUSFS v2.3.0 ====================
echo ""
echo "=== Application du patch SUSFS v2.3.0 ==="

SUSFS_PATCH=$(find "$GITHUB_WORKSPACE" -maxdepth 1 \( -name "*.patch" -o -name "susfs*.diff" \) -print -quit 2>/dev/null)

if [ -z "$SUSFS_PATCH" ]; then
    echo "❌ Aucun fichier .patch trouvé à la racine de $GITHUB_WORKSPACE"
    exit 1
fi

echo "✅ Fichier de patch trouvé : $SUSFS_PATCH"
patch -p1 --forward < "$SUSFS_PATCH" || true

REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
    echo "⚠️  $REJ_COUNT hunk(s) rejeté(s) (V11.2 a booté malgré ça) :"
    find . -name "*.rej" 2>/dev/null
fi

# ==================== 3b. CORRECTIFS POST-PATCH SUSFS ====================
echo ""
echo "=== Correctifs post-patch SUSFS ==="

if ! grep -q "CONFIG_KSU_SUSFS.*susfs.o" fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
    echo "    ✅ fs/Makefile : ligne susfs.o ajoutée"
fi

# Force super.c — V11.4 : print ✅ UNIQUEMENT si le replace a réellement matché
python3 - <<'PYEOF'
import os
def force_super_c():
    with open('fs/super.c', 'r') as f:
        c = f.read()
    changed = False
    if '#include <linux/susfs_def.h>' not in c:
        marker = '#include <linux/user_namespace.h>'
        if marker in c:
            c = c.replace(marker, marker + '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#include <linux/susfs.h>\n#include <linux/jump_label.h>\n#endif', 1)
            changed = True
            print("    ✅ fs/super.c : includes SUSFS ajoutés")
        else:
            print("    ⚠️  fs/super.c : marqueur 'user_namespace.h' introuvable — includes NON ajoutés")
    else:
        print("    → fs/super.c : includes déjà présents")

    if 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted' not in c:
        marker = '#include "internal.h"'
        if marker in c:
            c = c.replace(marker, marker + '\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#endif', 1)
            changed = True
            print("    ✅ fs/super.c : externs ajoutés")
        else:
            print("    ⚠️  fs/super.c : marqueur 'internal.h' introuvable — externs NON ajoutés")

    if changed:
        with open('fs/super.c', 'w') as f:
            f.write(c)

force_super_c()
PYEOF

python3 - <<'PYEOF'
import os
def force_include(filepath, includes):
    if not os.path.exists(filepath): return
    with open(filepath, 'r') as f: lines = f.readlines()
    insert_idx = 0; in_comment = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('/*'): in_comment = True
        if in_comment:
            if '*/' in stripped: in_comment = False
            continue
        if stripped.startswith('//') or stripped == '': continue
        insert_idx = i; break
    new_lines = [inc + '\n' for inc in includes if inc not in lines]
    if new_lines:
        lines = lines[:insert_idx] + new_lines + lines[insert_idx:]
        with open(filepath, 'w') as f: f.writelines(lines)
        print(f"    ✅ Includes forcés dans {filepath}")
for f in ['fs/stat.c', 'fs/open.c', 'fs/namespace.c']:
    force_include(f, ['#include <linux/susfs.h>', '#include <linux/susfs_def.h>'])
PYEOF

python3 - <<'PYEOF'
with open('include/linux/susfs_def.h', 'r') as f: sd = f.read()
if 'CMD_SUSFS_SET_PRIORITY_UID_FILTER' not in sd:
    sd += '\n#ifndef CMD_SUSFS_SET_PRIORITY_UID_FILTER\n#define CMD_SUSFS_SET_PRIORITY_UID_FILTER 0x55551\n#endif\n'
    print("    ✅ CMD_SUSFS_SET_PRIORITY_UID_FILTER ajouté")
if 'DEFAULT_KSU_MNT_MINOR_DEV' not in sd:
    sd += '\n#ifndef DEFAULT_KSU_MNT_MINOR_DEV\n#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 12)\n#endif\n'
    print("    ✅ DEFAULT_KSU_MNT_MINOR_DEV ajouté")
with open('include/linux/susfs_def.h', 'w') as f: f.write(sd)
PYEOF

python3 - <<'PYEOF'
with open('fs/susfs.c', 'r') as f: sc = f.read()
if 'void susfs_parse_priority_app_strings(void)' not in sc:
    sc += '\nvoid susfs_parse_priority_app_strings(void) { }\n'
    print("    ✅ susfs_parse_priority_app_strings ajouté (stub)")
if 'void susfs_set_priority_uid_filter(u64 arg)' not in sc:
    sc += '\nvoid susfs_set_priority_uid_filter(u64 arg) { }\n'
    print("    ✅ susfs_set_priority_uid_filter ajouté (stub)")
with open('fs/susfs.c', 'w') as f: f.write(sc)
PYEOF

echo "✅ Correctifs post-patch appliqués"

# ==================== 3c. CORRECTIFS namespace + prototypes ====================
echo ""
echo "=== Correctifs namespace + prototypes ==="

python3 - <<'PYEOF'
with open('fs/namespace.c', 'r') as f: c = f.read()
if 'extern bool susfs_is_current_ksu_domain(void);' not in c:
    marker = '#include "internal.h"'
    if marker in c:
        extern_block = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif
'''
        c = c.replace(marker, marker + '\n' + extern_block, 1)
        print("    ✅ fs/namespace.c : externs + CL_COPY_MNT_NS ajoutés")
    else:
        print("    ⚠️  fs/namespace.c : marqueur 'internal.h' introuvable")
else:
    print("    → fs/namespace.c : externs déjà présents")
with open('fs/namespace.c', 'w') as f: f.write(c)
PYEOF

python3 - <<'PYEOF'
with open('include/linux/susfs.h', 'r') as f: sh = f.read()
if 'susfs_parse_priority_app_strings' not in sh:
    sh += '\nextern void susfs_parse_priority_app_strings(void);\n'
    print("    ✅ susfs.h : prototype susfs_parse_priority_app_strings")
if 'susfs_set_priority_uid_filter' not in sh:
    sh += '\nextern void susfs_set_priority_uid_filter(u64 arg);\n'
    print("    ✅ susfs.h : prototype susfs_set_priority_uid_filter")
with open('include/linux/susfs.h', 'w') as f: f.write(sh)
PYEOF

python3 - <<'PYEOF'
import os
def force_include(filepath, includes):
    if not os.path.exists(filepath): return
    with open(filepath, 'r') as f: lines = f.readlines()
    insert_idx = 0; in_comment = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('/*'): in_comment = True
        if in_comment:
            if '*/' in stripped: in_comment = False
            continue
        if stripped.startswith('//') or stripped == '': continue
        insert_idx = i; break
    new_lines = [inc + '\n' for inc in includes if inc not in lines]
    if new_lines:
        lines = lines[:insert_idx] + new_lines + lines[insert_idx:]
        with open(filepath, 'w') as f: f.writelines(lines)
        print(f"    ✅ Includes forcés dans {filepath}")
for f in ['drivers/kernelsu/manager/pkg_observer.c', 'drivers/kernelsu/supercall/dispatch.c']:
    force_include(f, ['#include <linux/susfs.h>'])
PYEOF

echo "✅ Correctifs namespace/prototypes appliqués"

# ==================== 4. SUSFS INLINE HOOK PATCHES (JackA1ltman) ====================
echo ""
echo "=== Exécution de susfs_inline_hook_patches.sh ==="

curl -LSs "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/susfs_inline_hook_patches.sh" -o /tmp/susfs_inline_hook_patches.sh
chmod +x /tmp/susfs_inline_hook_patches.sh
# V11.4 : on log le code retour mais on ne sort pas — V11.2 a booté malgré un
# succès incertain de ce script. Utile juste pour la traçabilité.
if bash /tmp/susfs_inline_hook_patches.sh; then
    echo "✅ susfs_inline_hook_patches.sh OK (rc=0)"
else
    INLINE_RC=$?
    echo "⚠️  susfs_inline_hook_patches.sh a retourné rc=$INLINE_RC — SUSFS peut être partiellement appliqué"
    echo "    On continue quand même (V11.2 a booté avec le même script)."
fi

# ==================== 4b. MANUAL HOOKS KERNELSU (V7.24) ← CORRECTION CLÉ ====================
# - ksu_handle_execveat  : identifie le manager au lancement (supercall entrance)
# - ksu_handle_faccessat : détection d'accès fichier par le manager
# - ksu_handle_stat      : profil / détection process
# Sans ces 3 hooks, termux marche (grâce au binaire su setuid) mais le manager
# ne reçoit jamais de réponse du noyau → "communication impossible".
echo ""
echo "=== 4b. Injection manual hooks KernelSU (supercall) ==="

# --- 4b.1 : fs/exec.c → ksu_handle_execveat ---
EXEC_C="fs/exec.c"
if grep -q 'do_execveat_common' "$EXEC_C"; then
    python3 - "$EXEC_C" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
if 'ksu_handle_execveat' not in c:
    pattern = r'(static int do_execveat_common\([^)]*\)\s*\{)'
    replacement = r'''\1
#ifdef CONFIG_KSU
    {
        extern int ksu_handle_execveat(int *, struct filename **, void *, void *, int *);
        ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
    }
#endif
'''
    c = re.sub(pattern, replacement, c, count=1)
    with open(sys.argv[1], 'w') as f: f.write(c)
    print("  ✅ ksu_handle_execveat injecté dans fs/exec.c")
else:
    print("  → ksu_handle_execveat déjà présent")
PYEOF
fi
grep -q 'ksu_handle_execveat' "$EXEC_C" || { echo "❌ hook execveat non injecté dans $EXEC_C"; exit 1; }

# --- 4b.2 : fs/open.c → ksu_handle_faccessat ---
OPEN_C="fs/open.c"
if grep -q 'SYSCALL_DEFINE3(faccessat' "$OPEN_C"; then
    python3 - "$OPEN_C" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
if 'ksu_handle_faccessat' not in c:
    pattern = r'(SYSCALL_DEFINE3\(faccessat,\s*int,\s*dfd,\s*const char __user \*,\s*filename,\s*int,\s*mode\)\s*\{)'
    replacement = r'''\1
#ifdef CONFIG_KSU
    {
        extern int ksu_handle_faccessat(int *, const char __user **, int *, int *);
        ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
    }
#endif
'''
    c = re.sub(pattern, replacement, c, count=1)
    with open(sys.argv[1], 'w') as f: f.write(c)
    print("  ✅ ksu_handle_faccessat injecté dans fs/open.c")
else:
    print("  → ksu_handle_faccessat déjà présent")
PYEOF
fi
grep -q 'ksu_handle_faccessat' "$OPEN_C" || { echo "❌ hook faccessat non injecté dans $OPEN_C"; exit 1; }

# --- 4b.3 : fs/stat.c → ksu_handle_stat ---
STAT_C="fs/stat.c"
if grep -q 'SYSCALL_DEFINE4(newfstatat' "$STAT_C"; then
    python3 - "$STAT_C" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
if 'ksu_handle_stat' not in c:
    pattern = r'(SYSCALL_DEFINE4\(newfstatat,\s*int,\s*dfd,\s*const char __user \*,\s*filename,\s*struct stat __user \*,\s*statbuf,\s*int,\s*flag\)\s*\{)'
    replacement = r'''\1
#ifdef CONFIG_KSU
    {
        extern int ksu_handle_stat(int *, const char __user **, int *);
        ksu_handle_stat(&dfd, &filename, &flag);
    }
#endif
'''
    c = re.sub(pattern, replacement, c, count=1)
    with open(sys.argv[1], 'w') as f: f.write(c)
    print("  ✅ ksu_handle_stat injecté dans fs/stat.c")
else:
    print("  → ksu_handle_stat déjà présent")
PYEOF
fi
grep -q 'ksu_handle_stat' "$STAT_C" || { echo "❌ hook stat non injecté dans $STAT_C"; exit 1; }

echo "✅ 3 hooks KernelSU injectés et vérifiés"

# ==================== 5. FIXES COMPATIBILITÉ 4.19 ====================
echo ""
echo "=== Fixes compatibilité 4.19 ==="

if [ ! -f "include/linux/static_call.h" ]; then
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

for f in drivers/kernelsu/ksu.c drivers/kernelsu/ksu_main.c drivers/kernelsu/core/init.c; do
    if [ -f "$f" ]; then
        sed -i 's|MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,0,0)\nMODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);\n#endif|' "$f"
    fi
done

for f in drivers/kernelsu/infra/file_wrapper.c drivers/kernelsu/file_wrapper.c; do
    [ ! -f "$f" ] && continue
    python3 - "$f" <<'PYEOF'
import sys
with open(sys.argv[1]) as f: c = f.read()
c = c.replace('return orig->f_op->iopoll(kiocb, spin);', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,1,0)\n        return orig->f_op->iopoll(kiocb, spin);\n#else\n        return -EOPNOTSUPP;\n#endif')
c = c.replace('p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,1,0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif')
c = c.replace('if (remap_flags & REMAP_FILE_DEDUP) {', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,20,0)\n    if (remap_flags & REMAP_FILE_DEDUP) {\n#else\n    if (0) {\n#endif')
c = c.replace('return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,20,0)\n        return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif')
c = c.replace('return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,20,0)\n        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif')
c = c.replace('p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,20,0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif')
c = c.replace('struct file *orig = data->orig;', 'struct file *orig __maybe_unused = data->orig;')
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
done

for f in drivers/kernelsu/infra/seccomp_cache.c drivers/kernelsu/seccomp_cache.c; do
    [ ! -f "$f" ] && continue
    if ! grep -q '#ifndef SECCOMP_ARCH_NATIVE_NR' "$f"; then
        python3 - "$f" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
fb = '\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n#endif\n#ifndef SECCOMP_ARCH_COMPAT_NR\n#define SECCOMP_ARCH_COMPAT_NR NR_syscalls\n#endif\n'
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
if m: c = c[:m.end()] + fb + c[m.end():]
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
    fi
done

for f in drivers/kernelsu/infra/su_mount_ns.c drivers/kernelsu/su_mount_ns.c; do
    [ -f "$f" ] && sed -i 's|#include <uapi/linux/mount.h>|#include <linux/mount.h>|' "$f"
done

for f in drivers/kernelsu/manager/pkg_observer.c drivers/kernelsu/pkg_observer.c; do
    [ ! -f "$f" ] && continue
    python3 - "$f" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
c = c.replace('.handle_inode_event = ksu_handle_inode_event,', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,9,0)\n\t.handle_inode_event = ksu_handle_inode_event,\n#endif')
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
done

for f in drivers/kernelsu/policy/allowlist.c drivers/kernelsu/allowlist.c drivers/kernelsu/supercall/supercall.c; do
    [ ! -f "$f" ] && continue
    python3 - "$f" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
if 'TWA_RESUME' in c and '#ifndef TWA_RESUME' not in c:
    fb = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 1\n#endif\n'
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
    if m: c = c[:m.end()] + fb + c[m.end():]
if '#include <linux/sched/task.h>' not in c:
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
    if m: c = c[:m.end()] + '#include <linux/sched/task.h>\n' + c[m.end():]
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
done

for f in drivers/kernelsu/policy/app_profile.c drivers/kernelsu/app_profile.c; do
    [ ! -f "$f" ] && continue
    sed -i 's|atomic_set(&current->seccomp.filter_count, 0);|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,9,0)\n\tatomic_set(\&current->seccomp.filter_count, 0);\n#endif|' "$f"
done

if [ -f "drivers/kernelsu/extension/cpu_spoof.c" ]; then
    python3 - drivers/kernelsu/extension/cpu_spoof.c <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
c = c.replace('(*curr_cs_ptr)->vdso_clock_mode =', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,7,0)\n                        (*curr_cs_ptr)->vdso_clock_mode =')
c = re.sub(r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5,7,0\)\n\s*\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)', r'\1\n#endif', c)
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
fi

[ -f "drivers/kernelsu/sulog/event.c" ] && sed -i 's|#include <linux/minmax.h>|#include <linux/kernel.h>|' drivers/kernelsu/sulog/event.c
[ -f "drivers/kernelsu/preinit/common/preinit.h" ] && sed -i 's|^#define KSU_NO_PREINIT$|#define KSU_NO_PREINIT 1|' drivers/kernelsu/preinit/common/preinit.h

find drivers/kernelsu/sulog \( -name '*.c' -o -name '*.h' \) 2>/dev/null | while read f; do
    sed -i 's|#define USER_ARG_NULL user_arg_null_ptr()|#define USER_ARG_NULL (*user_arg_null_ptr())|' "$f"
done

KPM="drivers/kernelsu/extension/kpm/kpm.c"
if [ -f "$KPM" ]; then
    sed -i 's/ksu_access_ok(/__AOK__PH__(/g' "$KPM"
    sed -i 's/access_ok(/ksu_access_ok(/g' "$KPM"
    sed -i 's/__AOK__PH__(/ksu_access_ok(/g' "$KPM"
fi
COMPAT="drivers/kernelsu/kernel_compat.h"
if [ -f "$COMPAT" ] && ! grep -q 'define ksu_access_ok' "$COMPAT"; then
    python3 - "$COMPAT" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
macro = '\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5,0,0)\n#define ksu_access_ok(addr, size) access_ok(VERIFY_READ, addr, size)\n#else\n#define ksu_access_ok(addr, size) access_ok(addr, size)\n#endif\n'
m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m: c = c[:m[-1].end()] + macro + c[m[-1].end():]
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
fi

FEAT="drivers/kernelsu/include/uapi/feature.h"
if [ -f "$FEAT" ]; then
    python3 - "$FEAT" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: lines = f.readlines()
new = [l for l in lines if not re.search(r'KSU_FEATURE_SELINUX_HIDE\s*=', l)]
final = []; inserted = False
for l in new:
    final.append(l)
    if not inserted and re.search(r'KSU_FEATURE_MOUNT_HIDE\s*=\s*\d+\s*,', l):
        m = re.match(r'^(\s*)', l); ind = m.group(1) if m else '\t'
        final.append(f'{ind}KSU_FEATURE_SELINUX_HIDE = 17,\n'); inserted = True
if not inserted:
    for i, l in enumerate(final):
        if l.strip() == '};':
            final.insert(i, '\tKSU_FEATURE_SELINUX_HIDE = 17,\n'); inserted = True; break
if inserted:
    with open(sys.argv[1], 'w') as f: f.writelines(final)
PYEOF
fi

python3 - <<'PYEOF'
import re
with open('fs/namespace.c') as f: c = f.read()
if 'int path_umount(struct path *path, int flags)' not in c:
    bp = '''
#ifdef CONFIG_KSU
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW)) return -EINVAL;
	if (!may_mount()) return -EPERM;
	if (path->dentry != path->mnt->mnt_root) return -EINVAL;
	if (!check_mnt(mnt)) return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN)) return -EPERM;
	return 0;
}
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret = can_umount(path, flags);
	if (!ret) ret = do_umount(mnt, flags);
	dput(path->dentry); mntput_no_expire(mnt);
	return ret;
}
#endif
'''
    c = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', bp + r'\1', c, count=1)
if 'int path_mount(' not in c:
    bm = '''
#ifdef CONFIG_KSU
int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags, void *data_page)
{
    char *page = (char *)__get_free_page(GFP_KERNEL);
    char *p; int ret; mm_segment_t old_fs;
    if (!page) return -ENOMEM;
    p = d_path(path, page, PAGE_SIZE);
    if (IS_ERR(p)) { ret = PTR_ERR(p); goto out_free; }
    old_fs = get_fs(); set_fs(KERNEL_DS);
    ret = do_mount(dev_name, (const char __user *)p, type_page, flags, data_page);
    set_fs(old_fs);
out_free: free_page((unsigned long)page); return ret;
}
#endif
'''
    c = c.replace('int ksys_umount(', bm + '\nint ksys_umount(')
with open('fs/namespace.c', 'w') as f: f.write(c)
PYEOF

# ==================== 6. BACKPORT SELINUX 4.19 ====================
echo ""
echo "=== Backport SELinux pour 4.19 ==="
RULES="drivers/kernelsu/selinux/rules.c"
if [ -f "$RULES" ]; then
    python3 - "$RULES" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
if 'SELINUX_POLICY_INSTEAD_SELINUX_SS' not in c:
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
    if m:
        compat = '\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#define SELINUX_POLICY_INSTEAD_SELINUX_SS\n#endif\n'
        c = c[:m.end()] + compat + c[m.end():]
c = c.replace('return &selinux_state.ss;',
    '''#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS\n    return &rcu_dereference(selinux_state.policy)->policydb;\n#else\n    return &rcu_dereference(selinux_state.ss)->policydb;\n#endif''')
with open(path, 'w') as f: f.write(c)
PYEOF
fi
SEPOLICY="drivers/kernelsu/selinux/sepolicy.c"
if [ -f "$SEPOLICY" ]; then
    python3 - "$SEPOLICY" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
c = re.sub(r'struct selinux_policy \*(\w+)', r'struct policydb *\1', c)
c = re.sub(r'(\w+)->policydb', r'\1', c)
with open(path, 'w') as f: f.write(c)
PYEOF
fi

# ==================== 7. CONFIGURATION ====================
echo ""
echo "=== Configuration SukiSU-Ultra + SUSFS (full) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES is not set
# CONFIG_KSU_KPROBES_KSUD is not set
# CONFIG_KSU_TRACEPOINT_HOOK is not set
# CONFIG_KSU_HACK_ARM64_BRANCH_LINK is not set
# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU_FEATURE_SULOG=y
CONFIG_KSU_FEATURE_ADBROOT=y

# SUSFS v2.3.0 (full)
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
# CONFIG_KSU_SUSFS_ENABLE_LOG is not set
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y

# Dépendances non-GKI
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_THREAD_INFO_IN_TASK=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3
grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ CONFIG_KSU=y manquant"; exit 1; }

echo "=== État config SUSFS ==="
grep -E "CONFIG_KSU_SUSFS|CONFIG_KSU=y|CONFIG_KSU_MANUAL_HOOK=y|CONFIG_KSU_KPROBES|CONFIG_KSU_TRACEPOINT" out/.config | head -20

# ==================== 8. PATCHS MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* Patch Tactile */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 9. COMPILATION KERNEL ====================
echo ""
echo "=== Compilation kernel ==="
set +eo pipefail
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-macro-redefined -Wno-unused-variable -Wno-declaration-after-statement" \
  -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED (make rc=$MAKE_RC)"
    echo "--- Erreurs ---"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -30 || true
    echo "--- .rej éventuels ---"
    find . -name "*.rej" 2>/dev/null | head -10 || true
    exit 1
fi

echo "✅✅✅ COMPILATION RÉUSSIE AVEC SUSFS + MANUAL HOOKS ✅✅✅"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt

# ==================== 10. SAUVEGARDE DU NOYAU ====================
mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v11.4-susfs"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v11.4-susfs"
echo "✅ Image + System.map sauvegardés dans $GITHUB_WORKSPACE/output/"

# ==================== 11. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly 2>&1 | tail -3 || true
source "$HOME/.cargo/env" || true
rustup target add aarch64-linux-android 2>&1 | tail -2 || true
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip || true
unzip -q android-ndk-r26d-linux.zip || true
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 --branch builtin https://github.com/ShirkNeko/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src" || true

KSUD_OK=0
KSUD_DIR=$(find "$GITHUB_WORKSPACE/ksud-src" -name 'Cargo.toml' -type f 2>/dev/null | while read cargo; do
    if grep -qE 'name\s*=\s*"ksud"' "$cargo" 2>/dev/null; then dirname "$cargo"; break; fi
done | head -1 || true)

if [ -n "${KSUD_DIR:-}" ]; then
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
    set +eo pipefail
    cargo build --release --target aarch64-linux-android 2>&1 | tail -10
    CARGO_RC=${PIPESTATUS[0]}
    set -eo pipefail
    if [ "$CARGO_RC" -eq 0 ]; then
        KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1 || true)
        if [ -n "${KSUD_BINARY:-}" ]; then
            cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/output/ksud-v11.4"
            cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
            chmod 755 "$GITHUB_WORKSPACE/ksud"
            KSUD_OK=1
            echo "✅ ksud compilé"
        fi
    fi
fi
cd "$GITHUB_WORKSPACE"

# ==================== 12. REPACK ====================
echo ""
echo "=== Repack ==="
set +e
rm -f ./boot-stock.img ./dtbo-stock.img 2>/dev/null
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img

if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img introuvable (Google Drive bloqué ou ID invalide)."
    echo "⚠️  Le noyau est DISPONIBLE dans : $GITHUB_WORKSPACE/output/Image-v11.4-susfs"
    exit 1
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

if [ "${KSUD_OK:-0}" = "1" ] && [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
    cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f ./local_su_binary
    echo "✅ ksud + su dans le ramdisk"
fi

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v11.4-boot.img"
cd "$GITHUB_WORKSPACE"
set -e

# ==================== 13. SORTIE FINALE ====================
echo ""
echo "=== BUILD TERMINÉ v11.4 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
