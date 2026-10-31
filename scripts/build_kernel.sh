#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.41 : SukiSU-Ultra builtin + SUSFS (Fusion V7.24 + V7.40)
#         - Base V7.24 : CONFIG_KSU_MANUAL_HOOK=y + Hooks manuels
#         - Ajout SUSFS sans casser la communication du Manager
# =============================================================================

echo "=== Build SukiSU-Ultra builtin — V7.41 ==="
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
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 \
      || { echo "❌ patch SUSFS a échoué"; cat /tmp/susfs_patch.log; exit 1; }
    echo "  ✅ patch SUSFS appliqué"
else
    echo "  ⚠️ Patch SUSFS partiellement rejeté — correction manuelle"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true

    python3 - <<'PYEOF'
import re, sys
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
if 'susfs_is_current_ksu_domain' in c:
    print("  ↻ fs/namespace.c : blocs SUSFS déjà présents, skip"); sys.exit(0)
anchor1 = '#include "internal.h"\n'
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
bloc2 = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
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
label = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
c = c[:match2.end()] + label + c[match2.end():]
with open(path, 'w') as f: f.write(c)
print("  ✅ fs/namespace.c : blocs SUSFS injectés manuellement")
PYEOF
fi

# --- Correction DEFAULT_KSU_MNT_ID ---
python3 - <<'PYEOF'
import sys
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
if '#define DEFAULT_KSU_MNT_ID' not in c and 'DEFAULT_KSU_MNT_ID' in c:
    anchor = '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */'
    if anchor in c:
        c = c.replace(anchor, anchor + '\n#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n', 1)
    else:
        c = '#define DEFAULT_KSU_MNT_ID 500000\n#define DEFAULT_KSU_MNT_GROUP_ID 5000\n' + c
    with open(path, 'w') as f: f.write(c)
    print("  ✅ DEFAULT_KSU_MNT_ID ajouté")
PYEOF

find . -name "*.rej" -delete 2>/dev/null || true

if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi

# -----------------------------------------------------------------------------
# 3. FIXES COMPATIBILITÉ 4.19 (V7.24 + V7.40)
# -----------------------------------------------------------------------------
echo ""
echo "=== Fixes compatibilité 4.19 ==="

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
    grep -q 'SECCOMP_ARCH_NATIVE_NR' "$f" && continue
    python3 - "$f" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
fb = '\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n#endif\n#ifndef SECCOMP_ARCH_COMPAT_NR\n#define SECCOMP_ARCH_COMPAT_NR NR_syscalls\n#endif\n'
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
if m: c = c[:m.end()] + fb + c[m.end():]
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
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
for inc in ['#include <linux/sched.h>', '#include <linux/sched/task.h>', '#include <linux/init_task.h>']:
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

find drivers/kernelsu/sulog -name '*.c' -o -name '*.h' 2>/dev/null | while read f; do
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
final = []
inserted = False
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

# -----------------------------------------------------------------------------
# 3b. Corrections spécifiques SUSFS (fdinfo, cpu_spoof, kpm)
# -----------------------------------------------------------------------------
echo "  → Correction fs/notify/fdinfo.c (SUSFS)"
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
    print("  ✅ fdinfo.c corrigé")
PYEOF

# -----------------------------------------------------------------------------
# 3c. PATH_UMOUNT & PATH_MOUNT (V7.24)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 4. BACKPORT SELINUX 4.19 (V7.24)
# -----------------------------------------------------------------------------
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
c = c.replace('return &selinux_state.ss;', '#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS\n    return &rcu_dereference(selinux_state.policy)->policydb;\n#else\n    return &rcu_dereference(selinux_state.ss)->policydb;\n#endif')
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

KSUD="drivers/kernelsu/runtime/ksud.c"
if [ -f "$KSUD" ] && ! grep -q 'ksu_selinux_hide_handle_post_fs_data(void) { }' "$KSUD"; then
    python3 - "$KSUD" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f: c = f.read()
stubs = '\n#ifndef CONFIG_KSU_SUSFS\nstatic inline void ksu_selinux_hide_handle_post_fs_data(void) { }\nstatic inline void ksu_selinux_hide_handle_second_stage(void) { }\nstatic inline void ksu_selinux_hide_drop_backup_if_unused(void) { }\n#endif\n'
m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', c))
if m: c = c[:m[-1].end()] + stubs + c[m[-1].end():]
else: c = stubs + c
with open(sys.argv[1], 'w') as f: f.write(c)
PYEOF
fi

# -----------------------------------------------------------------------------
# 5. INJECTION MANUAL HOOKS (V7.24 - CRUCIAL POUR LE MANAGER)
# -----------------------------------------------------------------------------
echo ""
echo "=== Injection des manual hooks (V7.24) ==="

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

# -----------------------------------------------------------------------------
# 6. CONFIGURATION (MANUAL HOOK + SUSFS)
# -----------------------------------------------------------------------------
echo ""
echo "=== Configuration SukiSU-Ultra (Manual Hooks + SUSFS) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
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
grep -q '^CONFIG_KSU=y' out/.config || { echo "❌ KSU"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK=y' out/.config || { echo "❌ MANUAL_HOOK droppé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y' out/.config || { echo "❌ SUSFS droppé"; exit 1; }

# -----------------------------------------------------------------------------
# 7. PATCHS MOTOROLA
# -----------------------------------------------------------------------------
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* Patch Tactile */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# -----------------------------------------------------------------------------
# 8. COMPILATION KERNEL
# -----------------------------------------------------------------------------
echo ""
echo "=== Compilation kernel ==="
set +eo pipefail
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" \
  -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -30
    exit 1
fi
echo "✅✅✅ COMPILATION RÉUSSIE ✅✅✅"

KSU_SYMS=$(grep -E 'ksu_handle_execveat|ksu_handle_stat|ksu_handle_faccessat' out/System.map || true)
if [ -z "$KSU_SYMS" ]; then echo "❌ Symboles KSU absents"; exit 1; fi

mkdir -p "$GITHUB_WORKSPACE/output"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-v7.41"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-v7.41"

# -----------------------------------------------------------------------------
# 9. RÉCUPÉRATION KSUD (Release officielle)
# -----------------------------------------------------------------------------
echo ""
echo "=== Récupération de ksud ==="
cd "$GITHUB_WORKSPACE"
KSUD_URL=$(curl -s https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/releases/latest \
    | grep "browser_download_url" | grep -i "ksud" | grep -i "aarch64" | cut -d '"' -f 4 | head -1)

if [ -n "$KSUD_URL" ] && wget -q "$KSUD_URL" -O "$GITHUB_WORKSPACE/ksud"; then
    chmod 755 "$GITHUB_WORKSPACE/ksud"
    KSUD_OK=1
    echo "✅ ksud téléchargé : $KSUD_URL"
else
    echo "⚠️ Échec téléchargement ksud"
    KSUD_OK=0
fi

# -----------------------------------------------------------------------------
# 10. REPACK
# -----------------------------------------------------------------------------
echo ""
echo "=== Repack ==="
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
fi

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$GITHUB_WORKSPACE/output/SukiSU-Ultra-SUSFS-v7.41-boot.img"
cd "$GITHUB_WORKSPACE"
echo "✅ boot.img repacké"

# -----------------------------------------------------------------------------
# 11. SORTIE FINALE
# -----------------------------------------------------------------------------
echo ""
echo "=== BUILD TERMINÉ v7.41 ==="
ls -lh "$GITHUB_WORKSPACE/output/"
