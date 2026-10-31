#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.25 : SukiSU-Ultra builtin — V7.24 (Manager OK) + SUSFS v2.3.0
# =============================================================================

echo "=== Build SukiSU-Ultra builtin — V7.25 (SUSFS) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev patch wget

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION SukiSU-Ultra ====================
echo "=== Intégration SukiSU-Ultra (builtin) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true
curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
[ ! -d "drivers/kernelsu" ] && echo "❌" && exit 1
echo "✅ intégré"

# ==================== 2b. TÉLÉCHARGEMENT ET APPLICATION DES PATCHS ====================
echo ""
echo "=== Téléchargement des patches de JackA1ltman (à jour) ==="
BASE_JACK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch"

curl -LSsf "$BASE_JACK/sukisu_ultra_fixed.patch" -o /tmp/sukisu_fixed.patch
curl -LSsf "$BASE_JACK/susfs_patch_to_4.19.patch" -o /tmp/susfs_4.19.patch

if [ ! -s /tmp/sukisu_fixed.patch ] || [ ! -s /tmp/susfs_4.19.patch ]; then
    echo "❌ Échec du téléchargement des patches depuis GitHub."
    exit 1
fi
echo "✅ Patches téléchargés."

echo ""
echo "=== Application de sukisu_ultra_fixed.patch ==="
patch -p1 -t --forward < /tmp/sukisu_fixed.patch || true

echo ""
echo "=== Application de susfs_patch_to_4.19.patch ==="
patch -p1 -t --forward < /tmp/susfs_4.19.patch || true

# ==================== 2c. FICHIERS SUSFS (SECOURS) ====================
echo ""
echo "=== Vérification / Récupération des 3 fichiers SUSFS ==="
BASE_GITLAB="https://gitlab.com/simonpunk/susfs4ksu/-/raw/master/kernel_patches"
BASE_GITHUB="https://raw.githubusercontent.com/Star-Seven/susfs4ksu/master/kernel_patches"

download_susfs() {
    local dest="$1"
    local path="$2"
    if [ -s "$dest" ]; then
        echo "  → $dest (déjà présent)"
        return 0
    fi
    echo "  → Téléchargement de secours de $dest..."
    if curl -LSsf "$BASE_GITLAB/$path" -o "$dest" 2>/dev/null; then return 0; fi
    if curl -LSsf "$BASE_GITHUB/$path" -o "$dest" 2>/dev/null; then return 0; fi
    echo "❌ Impossible de télécharger $path"
    exit 1
}

download_susfs "fs/susfs.c" "fs/susfs.c"
download_susfs "include/linux/susfs.h" "include/linux/susfs.h"
download_susfs "include/linux/susfs_def.h" "include/linux/susfs_def.h"

# ==================== 2d. CORRECTIFS POST-PATCH SUSFS ====================
echo ""
echo "=== Correctifs post-patch SUSFS ==="

if ! grep -q "CONFIG_KSU_SUSFS.*susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    echo "    ✅ fs/Makefile patché"
fi

# Includes forcés
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

for f in ['fs/stat.c', 'fs/open.c', 'fs/namespace.c', 'fs/super.c']:
    force_include(f, ['#include <linux/susfs.h>', '#include <linux/susfs_def.h>', '#include <linux/jump_label.h>'])
PYEOF

# Fix macros et variables manquantes
python3 - <<'PYEOF'
with open('include/linux/susfs_def.h', 'r') as f: sd = f.read()
if 'CMD_SUSFS_SET_PRIORITY_UID_FILTER' not in sd:
    sd += '\n#ifndef CMD_SUSFS_SET_PRIORITY_UID_FILTER\n#define CMD_SUSFS_SET_PRIORITY_UID_FILTER 0x55551\n#endif\n'
if 'DEFAULT_KSU_MNT_MINOR_DEV' not in sd:
    sd += '\n#ifndef DEFAULT_KSU_MNT_MINOR_DEV\n#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 12)\n#endif\n'
if 'CL_COPY_MNT_NS' not in sd:
    sd += '\n#ifndef CL_COPY_MNT_NS\n#define CL_COPY_MNT_NS BIT(25)\n#endif\n'
# FIX : Ajout de la déclaration manquante pour fs/super.c
if 'susfs_is_sdcard_android_data_not_decrypted' not in sd:
    sd += '\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n'
with open('include/linux/susfs_def.h', 'w') as f: f.write(sd)
PYEOF

# Fix stubs et variables dans susfs.c et susfs.h
python3 - <<'PYEOF'
with open('fs/susfs.c', 'r') as f: sc = f.read()
if 'susfs_parse_priority_app_strings' not in sc:
    sc += '\nvoid susfs_parse_priority_app_strings(void) { }\n'
if 'susfs_is_current_ksu_domain' not in sc:
    sc += '\nbool susfs_is_current_ksu_domain(void) { return false; }\n'
if 'susfs_set_priority_uid_filter' not in sc:
    sc += '\nvoid susfs_set_priority_uid_filter(void __user **user_info) { }\n'
if 'DEFINE_STATIC_KEY_FALSE(susfs_is_sdcard_android_data_not_decrypted)' in sc:
    sc = sc.replace('DEFINE_STATIC_KEY_FALSE(susfs_is_sdcard_android_data_not_decrypted)', 'DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted)')
with open('fs/susfs.c', 'w') as f: f.write(sc)

with open('include/linux/susfs.h', 'r') as f: sh = f.read()
if 'susfs_parse_priority_app_strings' not in sh:
    sh += '\nextern void susfs_parse_priority_app_strings(void);\n'
if 'susfs_is_current_ksu_domain' not in sh:
    sh += '\nextern bool susfs_is_current_ksu_domain(void);\n'
if 'susfs_set_priority_uid_filter' not in sh:
    sh += '\nextern void susfs_set_priority_uid_filter(void __user **user_info);\n'
with open('include/linux/susfs.h', 'w') as f: f.write(sh)
PYEOF

echo "✅ Correctifs post-patch appliqués"

# ==================== 3. FIXES COMPATIBILITÉ 4.19 (V7.24) ====================
echo ""
echo "=== Fixes compatibilité 4.19 (V7.24) ==="
[ ! -f "include/linux/static_call.h" ] && cat > include/linux/static_call.h <<'EOF'
#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H
#define static_call(name) (name##_static_call)
#define static_call_cond(name) (name##_static_call)
#define static_call_update(name, func) do { } while (0)
#define static_call_query(name) (name##_static_call)
#endif
EOF

for f in drivers/kernelsu/ksu.c drivers/kernelsu/ksu_main.c drivers/kernelsu/core/init.c; do
    [ -f "$f" ] && sed -i 's|MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,0,0)\nMODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);\n#endif|' "$f"
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
c = re.sub(r'(\s*)susfs_parse_priority_app_strings\(\);', r'\1#ifdef CONFIG_KSU_SUSFS\n\1susfs_parse_priority_app_strings();\n\1#endif', c)
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

[ -f "drivers/kernelsu/supercall/dispatch.c" ] && python3 - drivers/kernelsu/supercall/dispatch.c <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
for inc in ['#include <linux/sched.h>', '#include <linux/sched/task.h>', '#include <linux/init_task.h>', '#include <linux/susfs.h>']:
    if inc not in c:
        m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
        if m: c = c[:m.end()] + inc + '\n' + c[m.end():]
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF

for f in drivers/kernelsu/policy/app_profile.c drivers/kernelsu/app_profile.c; do
    [ ! -f "$f" ] && continue
    sed -i 's|atomic_set(&current->seccomp.filter_count, 0);|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,9,0)\n\tatomic_set(\&current->seccomp.filter_count, 0);\n#endif|' "$f"
done

[ -f "drivers/kernelsu/extension/cpu_spoof.c" ] && python3 - drivers/kernelsu/extension/cpu_spoof.c <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
c = c.replace('(*curr_cs_ptr)->vdso_clock_mode =', '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,7,0)\n                        (*curr_cs_ptr)->vdso_clock_mode =')
c = re.sub(r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5,7,0\)\n\s*\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)', r'\1\n#endif', c)
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF

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

KSUD="drivers/kernelsu/runtime/ksud.c"
if [ -f "$KSUD" ] && ! grep -q 'ksu_selinux_hide_handle_post_fs_data(void) { }' "$KSUD"; then
    python3 - "$KSUD" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
stubs = '\n/* V7.24 : stubs SUSFS */\n#ifndef CONFIG_KSU_SUSFS\nstatic inline void ksu_selinux_hide_handle_post_fs_data(void) { }\nstatic inline void ksu_selinux_hide_handle_second_stage(void) { }\nstatic inline void ksu_selinux_hide_drop_backup_if_unused(void) { }\n#endif\n'
m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m: c = c[:m[-1].end()] + stubs + c[m[-1].end():]
else: c = stubs + c
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
fi

# ==================== 4. BACKPORT SELINUX 4.19 ====================
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

# ==================== 5. INJECTION MANUAL HOOKS ====================
echo ""
echo "=== Injection des manual hooks ==="

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
    print("  ✅ execve hook injecté dans fs/exec.c")
PYEOF
fi

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
    print("  ✅ faccessat hook injecté dans fs/open.c")
PYEOF
fi

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
    print("  ✅ newfstatat hook injecté dans fs/stat.c")
PYEOF
fi

# ==================== 6. CONFIGURATION ====================
echo ""
echo "=== Configuration SukiSU-Ultra + SUSFS ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES is not set
# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU_FEATURE_SULOG=y
CONFIG_KSU_FEATURE_ADBROOT=y

# SUSFS (Partiel - Sécurisé pour le boot)
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
# CONFIG_KSU_SUSFS_SUS_MOUNT is not set       <-- COUPE ÇA (C'est lui qui panic)
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set   <-- COUPE ÇA AUSSI (Modifie le VFS)
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

echo "=== État config SUSFS ==="
grep -E "CONFIG_KSU_SUSFS|CONFIG_KSU=y|CONFIG_KSU_MANUAL_HOOK=y" out/.config | head -15
grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ KSU"; exit 1; }

# ==================== 7. PATCHS MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* Patch Tactile */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 8. COMPILATION KERNEL ====================
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
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -30 || true
    exit 1
fi
echo "✅✅✅ COMPILATION RÉUSSIE (V7.25) ✅✅✅"

# ==================== 9. SAUVEGARDE DU NOYAU ====================
mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.25-susfs"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.25-susfs"

# ==================== 10. COMPILATION KSUD ====================
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
done | head -1)

if [ -n "$KSUD_DIR" ]; then
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
        KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
        if [ -n "$KSUD_BINARY" ]; then
            cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/output/ksud-v7.25"
            cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
            chmod 755 "$GITHUB_WORKSPACE/ksud"
            KSUD_OK=1
            echo "✅ ksud compilé"
        fi
    fi
fi
cd "$GITHUB_WORKSPACE"

# ==================== 11. REPACK ====================
echo ""
echo "=== Repack ==="
set +e 
rm -f ./boot-stock.img ./dtbo-stock.img 2>/dev/null
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img

if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img introuvable (Google Drive bloqué)."
    echo "⚠️ On saute le repack, mais ton fichier Image est SAUVEGARDÉ dans $GITHUB_WORKSPACE/output/Image-v7.25-susfs"
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

if [ "${KSUD_OK:-0}" = "1" ] && [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
    cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f ./local_su_binary
    echo "✅ ksud + su inclus dans le ramdisk"
else
    echo "⚠️ Repack SANS ksud (le Manager l'installera au boot)"
fi

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v7.25-boot.img"
cd "$GITHUB_WORKSPACE"
echo "✅ boot.img repacké avec succès"
set -e

# ==================== 12. SORTIE FINALE ====================
echo ""
echo "=== BUILD TERMINÉ v7.25 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
