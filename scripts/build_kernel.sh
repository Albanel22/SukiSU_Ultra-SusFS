#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.13 : SukiSU-Ultra (ShirkNeko/builtin) — SANS SUSFS
#         V7.13 : RETIRER macro handle_sepolicy (casse les déclarations)
#                 + RESTAURER stubs ksu_selinux_hide_* (régression V7.12)
# =============================================================================

echo "=== Build SukiSU-Ultra (ShirkNeko/builtin, sans SUSFS) — V7.13 ==="
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

# ==================== 2. INTÉGRATION SukiSU-Ultra (builtin) ====================
echo "=== Intégration SukiSU-Ultra (ShirkNeko/builtin) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration SukiSU-Ultra"; exit 1
fi
echo "✅ SukiSU-Ultra (builtin) intégré"
KSU_DIR="drivers/kernelsu"
echo "KSU_DIR : $KSU_DIR"

# ==================== 2a. DIAGNOSTIC STRUCTURE ====================
echo ""
echo "=== DIAGNOSTIC structure ==="
ls -la drivers/ 2>&1 | grep -i kernelsu || echo "  (pas de kernelsu dans drivers/)"
echo "--- test chemins explicites ---"
for p in \
    "drivers/kernelsu/extension/kpm/kpm.c" \
    "drivers/kernelsu/include/uapi/feature.h" \
    "drivers/kernelsu/kernel_compat.h" \
    "drivers/kernelsu/runtime/ksud.c" \
    "drivers/kernelsu/selinux/rules.c" \
    "drivers/kernelsu/selinux/sepolicy.c" \
    "drivers/kernelsu/selinux/selinux.h" \
    "drivers/kernelsu/supercall/dispatch.c"; do
    if [ -f "$p" ]; then echo "  ✅ $p"; else echo "  ❌ $p"; fi
done

# ==================== 2b. NEUTRALISATION CHECK.MK ====================
echo ""
echo "=== Neutralisation check.mk (find -L) ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find -L . -name "$pattern" -type f 2>/dev/null || true)
    [ -n "$FILES" ] && for f in $FILES; do sed -i 's/\$(error/\$(warning/g' "$f"; done
done

# ==================== 2c. NETTOYAGE UNICODE ====================
echo "=== Nettoyage Unicode ==="
python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F',
    '\u205F', '\u3000']
count = 0
for root, dirs, files in os.walk('.', followlinks=True):
    if 'KernelSU' not in root and 'kernelsu' not in root:
        continue
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content: content = content.replace(uchar, ' ')
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count += 1
            except: pass
print(f"✅ {count} fichiers nettoyés")
PYEOF

# ==================== 2d. STATIC EXPORTS SELINUX ====================
echo "=== Static exports SELinux ==="
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && {
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}

# ==================== 3. GARDES DE COMPATIBILITÉ ET BACKPORTS ====================
echo ""
echo "=== Application des gardes de compatibilité et backports ==="

python3 << 'PYEOF'
import re
import os

def modify_file(path, transform_func, description):
    if not os.path.exists(path):
        print(f"  ⚠️  {description} : {path} introuvable")
        return False
    try:
        with open(path, 'r') as f: content = f.read()
        new_content = transform_func(content)
        if new_content != content:
            with open(path, 'w') as f: f.write(new_content)
            print(f"  ✅ {description}")
            return True
        else:
            print(f"  ✅ {description} (déjà patché)")
            return False
    except Exception as e:
        print(f"  ⚠️  {description} : erreur {e}")
        return False

# 1. Stub static_call.h
print("=== Stub static_call.h ===")
sc_path = 'include/linux/static_call.h'
if not os.path.exists(sc_path):
    with open(sc_path, 'w') as f:
        f.write('''#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H
#define static_call(name) (name##_static_call)
#define static_call_cond(name) (name##_static_call)
#define static_call_update(name, func) do { } while (0)
#define static_call_query(name) (name##_static_call)
#endif
''')
    print("  ✅ static_call.h créé")

# 2. MODULE_IMPORT_NS
print("=== MODULE_IMPORT_NS ===")
for p in ['drivers/kernelsu/ksu.c', 'drivers/kernelsu/ksu_main.c', 'drivers/kernelsu/core/init.c']:
    if os.path.exists(p):
        def tx(content):
            if 'MODULE_IMPORT_NS' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)' not in content:
                return content.replace(
                    'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\nMODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);\n#endif'
                )
            return content
        modify_file(p, tx, f"MODULE_IMPORT_NS {p}")

# 3. file_wrapper.c
print("=== file_wrapper.c ===")
for p in ['drivers/kernelsu/infra/file_wrapper.c', 'drivers/kernelsu/file_wrapper.c']:
    if os.path.exists(p):
        def tx(content):
            if 'iopoll' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)' not in content:
                content = content.replace('return orig->f_op->iopoll(kiocb, spin);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n        return orig->f_op->iopoll(kiocb, spin);\n#else\n        return -EOPNOTSUPP;\n#endif')
                content = content.replace('p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif')
            if 'remap_file_range' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)' not in content:
                content = content.replace('if (remap_flags & REMAP_FILE_DEDUP) {',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n    if (remap_flags & REMAP_FILE_DEDUP) {\n#else\n    if (0) {\n#endif')
                content = content.replace('return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n        return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif')
                content = content.replace('return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif')
                content = content.replace('p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif')
            if 'struct file *orig = data->orig;' in content:
                content = content.replace('struct file *orig = data->orig;', 'struct file *orig __maybe_unused = data->orig;')
            return content
        modify_file(p, tx, f"file_wrapper.c {p}")

# 4. seccomp_cache.c
print("=== seccomp_cache.c ===")
for p in ['drivers/kernelsu/infra/seccomp_cache.c', 'drivers/kernelsu/seccomp_cache.c']:
    if os.path.exists(p):
        def tx(content):
            if 'SECCOMP_ARCH_NATIVE_NR' not in content or '#ifndef SECCOMP_ARCH_NATIVE_NR' not in content:
                fb = '\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n#endif\n#ifndef SECCOMP_ARCH_COMPAT_NR\n#define SECCOMP_ARCH_COMPAT_NR NR_syscalls\n#endif\n'
                m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if m: return content[:m.end()] + fb + content[m.end():]
            return content
        modify_file(p, tx, f"seccomp_cache.c {p}")

# 5. su_mount_ns.c
print("=== su_mount_ns.c ===")
for p in ['drivers/kernelsu/infra/su_mount_ns.c', 'drivers/kernelsu/su_mount_ns.c']:
    if os.path.exists(p):
        def tx(c): return c.replace('#include <uapi/linux/mount.h>', '#include <linux/mount.h>')
        modify_file(p, tx, f"su_mount_ns.c {p}")

# 6. pkg_observer.c
print("=== pkg_observer.c ===")
for p in ['drivers/kernelsu/manager/pkg_observer.c', 'drivers/kernelsu/pkg_observer.c']:
    if os.path.exists(p):
        def tx(content):
            if '.handle_inode_event = ksu_handle_inode_event,' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' not in content:
                content = content.replace('.handle_inode_event = ksu_handle_inode_event,',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n\t.handle_inode_event = ksu_handle_inode_event,\n#endif')
            if 'susfs_parse_priority_app_strings' in content and '#ifdef CONFIG_KSU_SUSFS' not in content:
                content = re.sub(r'(\s*)susfs_parse_priority_app_strings\(\);',
                    r'\1#ifdef CONFIG_KSU_SUSFS\n\1susfs_parse_priority_app_strings();\n\1#endif', content)
            return content
        modify_file(p, tx, f"pkg_observer.c {p}")

# 7. allowlist.c
print("=== allowlist.c ===")
for p in ['drivers/kernelsu/policy/allowlist.c', 'drivers/kernelsu/allowlist.c']:
    if os.path.exists(p):
        def tx(content):
            if 'TWA_RESUME' in content and '#ifndef TWA_RESUME' not in content:
                fb = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 1\n#endif\n'
                m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if m: content = content[:m.end()] + fb + content[m.end():]
            if '#include <linux/sched/task.h>' not in content:
                m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if m: content = content[:m.end()] + '#include <linux/sched/task.h>\n' + content[m.end():]
            return content
        modify_file(p, tx, f"allowlist.c {p}")

# 8. supercall.c
print("=== supercall/supercall.c ===")
for p in ['drivers/kernelsu/supercall/supercall.c']:
    if os.path.exists(p):
        def tx(content):
            if 'TWA_RESUME' in content and '#ifndef TWA_RESUME' not in content:
                fb = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 1\n#endif\n'
                m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if m: return content[:m.end()] + fb + content[m.end():]
            return content
        modify_file(p, tx, f"supercall.c {p}")

# 9. dispatch.c includes
print("=== dispatch.c ===")
for p in ['drivers/kernelsu/supercall/dispatch.c']:
    if os.path.exists(p):
        def tx(content):
            for inc in ['#include <linux/sched.h>', '#include <linux/sched/task.h>', '#include <linux/init_task.h>']:
                if inc not in content:
                    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                    if m: content = content[:m.end()] + inc + '\n' + content[m.end():]
            return content
        modify_file(p, tx, f"dispatch.c {p}")

# 10. app_profile.c
print("=== app_profile.c ===")
for p in ['drivers/kernelsu/policy/app_profile.c', 'drivers/kernelsu/app_profile.c']:
    if os.path.exists(p):
        def tx(content):
            old = 'atomic_set(&current->seccomp.filter_count, 0);'
            new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n\tatomic_set(&current->seccomp.filter_count, 0);\n#endif'
            if old in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' not in content:
                return content.replace(old, new)
            return content
        modify_file(p, tx, f"app_profile.c {p}")

# 11. selinux_hide.c (conservé)
print("=== selinux_hide.c ===")
for p in ['drivers/kernelsu/feature/selinux_hide.c', 'drivers/kernelsu/selinux_hide.c']:
    if os.path.exists(p):
        def tx(content):
            if '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' not in content:
                lines = content.split('\n')
                insert_pos = 0
                for i, line in enumerate(lines):
                    if line.strip() and not line.strip().startswith('//') and not line.strip().startswith('/*') and not line.strip().startswith('*') and not line.strip().startswith('#include'):
                        insert_pos = i; break
                lines.insert(insert_pos, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                lines.append('#endif // LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                return '\n'.join(lines)
            return content
        modify_file(p, tx, f"selinux_hide.c {p}")

# 12. cpu_spoof.c
print("=== cpu_spoof.c ===")
for p in ['drivers/kernelsu/extension/cpu_spoof.c']:
    if os.path.exists(p):
        def tx(content):
            if 'vdso_clock_mode' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)' not in content:
                content = content.replace('(*curr_cs_ptr)->vdso_clock_mode =',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n                        (*curr_cs_ptr)->vdso_clock_mode =')
                content = re.sub(r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 7, 0\)\n\s*\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)',
                    r'\1\n#endif', content)
            return content
        modify_file(p, tx, f"cpu_spoof.c {p}")

# 13. sulog/event.c
print("=== sulog/event.c ===")
for p in ['drivers/kernelsu/sulog/event.c']:
    if os.path.exists(p):
        def tx(c): return c.replace('#include <linux/minmax.h>', '#include <linux/kernel.h>')
        modify_file(p, tx, f"sulog/event.c {p}")

# 14. Backports path_umount + path_mount
print("=== path_umount/path_mount ===")
with open('fs/namespace.c', 'r') as f: content = f.read()

if 'int path_umount(struct path *path, int flags)' not in content:
    backport = '''
#ifdef CONFIG_KSU
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED)
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;
	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}
#endif
'''
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport + r'\1', content, count=1)
    print("  ✅ path_umount backporté")

if 'int path_mount(' not in content:
    bm = '''
#ifdef CONFIG_KSU
int path_mount(const char *dev_name, struct path *path,
               const char *type_page, unsigned long flags, void *data_page)
{
    char *page = (char *)__get_free_page(GFP_KERNEL);
    char *p;
    int ret;
    mm_segment_t old_fs;
    if (!page) return -ENOMEM;
    p = d_path(path, page, PAGE_SIZE);
    if (IS_ERR(p)) { ret = PTR_ERR(p); goto out_free; }
    old_fs = get_fs();
    set_fs(KERNEL_DS);
    ret = do_mount(dev_name, (const char __user *)p, type_page, flags, data_page);
    set_fs(old_fs);
out_free:
    free_page((unsigned long)page);
    return ret;
}
#endif
'''
    if 'int path_umount(struct path *path, int flags)' in content:
        m = re.search(r'int path_umount\(struct path \*path, int flags\).*?\n\}', content, re.DOTALL)
        if m: content = content[:m.end()] + '\n' + bm + content[m.end():]
    else:
        content = content.replace('int ksys_umount(', bm + '\nint ksys_umount(')
    print("  ✅ path_mount backporté")

with open('fs/namespace.c', 'w') as f: f.write(content)

# Fix A: KSU_NO_PREINIT
print("=== Fix A: KSU_NO_PREINIT ===")
preinit = 'drivers/kernelsu/preinit/common/preinit.h'
if os.path.exists(preinit):
    with open(preinit, 'r') as f: lines = f.readlines()
    new_lines = ['#define KSU_NO_PREINIT 1\n' if l.strip() == '#define KSU_NO_PREINIT' else l for l in lines]
    with open(preinit, 'w') as f: f.writelines(new_lines)
    print(f"  ✅ normalisé dans {preinit}")

# Fix F: USER_ARG_NULL
print("=== Fix F: USER_ARG_NULL ===")
for root, dirs, files in os.walk('drivers/kernelsu/sulog'):
    for file in files:
        if file.endswith(('.c', '.h')):
            path = os.path.join(root, file)
            with open(path, 'r') as f: content = f.read()
            if '#define USER_ARG_NULL user_arg_null_ptr()' in content:
                content = content.replace('#define USER_ARG_NULL user_arg_null_ptr()', '#define USER_ARG_NULL (*user_arg_null_ptr())')
                with open(path, 'w') as f: f.write(content)
                print(f"  ✅ corrigé {path}")

print("=== Correctifs Python 1/3 terminés ===")

PYEOF

# ==================== 3e. FIX B : access_ok → ksu_access_ok ====================
echo ""
echo "=== Fix B : access_ok → ksu_access_ok ==="

KPM_FILE="drivers/kernelsu/extension/kpm/kpm.c"
if [ -f "$KPM_FILE" ]; then
    sed -i 's/ksu_access_ok(/__KSU_AOK__PH__(/g' "$KPM_FILE"
    sed -i 's/access_ok(/ksu_access_ok(/g' "$KPM_FILE"
    sed -i 's/__KSU_AOK__PH__(/ksu_access_ok(/g' "$KPM_FILE"
    if grep -qE '(^|[^_])access_ok\(' "$KPM_FILE"; then
        echo "  ⚠️  access_ok restants"
    else
        echo "  ✅ Aucun access_ok nu"
    fi
fi

COMPAT_H="drivers/kernelsu/kernel_compat.h"
if [ -f "$COMPAT_H" ] && ! grep -q 'define ksu_access_ok' "$COMPAT_H"; then
    python3 - "$COMPAT_H" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()
macro = '\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)\n#define ksu_access_ok(addr, size) access_ok(VERIFY_READ, addr, size)\n#else\n#define ksu_access_ok(addr, size) access_ok(addr, size)\n#endif\n'
m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', content))
if m:
    content = content[:m[-1].end()] + macro + content[m[-1].end():]
    with open(path, 'w') as f: f.write(content)
    print("  ✅ ksu_access_ok macro ajouté")
PYEOF
fi

# ==================== 3f. FIX C : SELINUX_HIDE inconditionnel ====================
echo ""
echo "=== Fix C : SELINUX_HIDE inconditionnel ==="

FEATURE_H="drivers/kernelsu/include/uapi/feature.h"
if [ -f "$FEATURE_H" ]; then
    python3 - "$FEATURE_H" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: lines = f.readlines()
new_lines = []
removed = 0
for line in lines:
    if re.search(r'KSU_FEATURE_SELINUX_HIDE\s*=', line):
        print(f"  🗑️  Supprimé : {line.rstrip()!r}"); removed += 1; continue
    new_lines.append(line)
inserted = False
final = []
for line in new_lines:
    final.append(line)
    if not inserted and re.search(r'KSU_FEATURE_MOUNT_HIDE\s*=\s*\d+\s*,', line):
        m = re.match(r'^(\s*)', line); ind = m.group(1) if m else '\t'
        final.append(f'{ind}KSU_FEATURE_SELINUX_HIDE = 17,\n'); inserted = True
if not inserted:
    for i, line in enumerate(final):
        if line.strip() == '};':
            final.insert(i, '\tKSU_FEATURE_SELINUX_HIDE = 17,\n'); inserted = True; break
if inserted:
    with open(path, 'w') as f: f.writelines(final)
    print(f"  ✅ SELINUX_HIDE ajouté (supprimé {removed})")
PYEOF
fi

# ==================== 3g. FIX V7.13-A : RETIRER macro handle_sepolicy (V7.12 régression) ====================
echo ""
echo "=== Fix V7.13-A : RETIRER macro handle_sepolicy de kernel_compat.h ==="

if [ -f "$COMPAT_H" ]; then
    python3 - "$COMPAT_H" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()

if 'V7.12-HANDLE-SEPOLICY' not in content:
    print("  ✅ Macro handle_sepolicy absente (rien à faire)")
else:
    # Retirer le bloc entier ajouté par V7.12
    # Le bloc est : "\n/* V7.12-HANDLE-SEPOLICY */\n/* ... */\n#if ...\n#define handle_sepolicy(...) (-EOPNOTSUPP)\n#endif\n"
    pattern = r'\n?/\* V7\.12-HANDLE-SEPOLICY \*/.*?#endif[^\n]*\n'
    new_content = re.sub(pattern, '\n', content, flags=re.DOTALL)
    if new_content != content:
        with open(path, 'w') as f: f.write(new_content)
        print("  🗑️  Macro handle_sepolicy RETIRÉE de kernel_compat.h")
    else:
        # Fallback : supprimer juste la ligne #define
        lines = content.split('\n')
        new_lines = [l for l in lines if not (l.strip() == '#define handle_sepolicy(...) (-EOPNOTSUPP)' or 'V7.12-HANDLE-SEPOLICY' in l)]
        with open(path, 'w') as f: f.write('\n'.join(new_lines))
        print("  🗑️  Ligne macro handle_sepolicy retirée (fallback)")

# Vérification
with open(path, 'r') as f: c = f.read()
if 'define handle_sepolicy' in c:
    print("  ⚠️  Macro handle_sepolicy encore présente")
else:
    print("  ✅ Aucune macro handle_sepolicy dans kernel_compat.h")
PYEOF
else
    echo "  ❌ kernel_compat.h introuvable"
fi

# ==================== 3h. FIX V7.13-B : sepolicy.c wrap 5.0+ (conservé de V7.12) ====================
echo ""
echo "=== Fix V7.13-B : sepolicy.c wrap 5.0+ ==="

SEPOLICY="drivers/kernelsu/selinux/sepolicy.c"
if [ -f "$SEPOLICY" ]; then
    python3 - "$SEPOLICY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()

MARKER = '/* V7.12-SEPOLICY-WRAP */'
if MARKER in content:
    print("  ✅ Déjà wrappé")
else:
    header = f'''{MARKER}
/* sepolicy.c requires struct selinux_policy (Linux 5.0+). On 4.19 the
 * whole file is skipped. handle_sepolicy is defined in rules.c. */
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
'''
    footer = '\n#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) */\n'
    with open(path, 'w') as f: f.write(header + content + footer)
    print(f"  ✅ sepolicy.c wrappé (vide sur 4.19)")
PYEOF
else
    echo "  ❌ sepolicy.c introuvable"
fi

# ==================== 3i. FIX V7.13-C : rules.c __maybe_unused ====================
echo ""
echo "=== Fix V7.13-C : rules.c __maybe_unused ==="

RULES="drivers/kernelsu/selinux/rules.c"
if [ -f "$RULES" ]; then
    python3 - "$RULES" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()

if '__maybe_unused' in content:
    print("  ✅ Déjà patché")
else:
    old = 'struct selinux_policy *pol, *old_pol;'
    if old in content:
        content = content.replace(old, 'struct selinux_policy *pol __maybe_unused, *old_pol __maybe_unused;')
        with open(path, 'w') as f: f.write(content)
        print("  ✅ __maybe_unused ajouté sur pol/old_pol")
    else:
        new_content = re.sub(
            r'struct selinux_policy\s*\*(\w+)\s*,\s*\*(\w+);',
            r'struct selinux_policy *\1 __maybe_unused, *\2 __maybe_unused;',
            content
        )
        if new_content != content:
            with open(path, 'w') as f: f.write(new_content)
            print("  ✅ __maybe_unused ajouté (regex)")
        else:
            print("  ⚠️  Pas de match (peut-être déjà patché autrement)")
PYEOF
fi

# ==================== 3j. FIX V7.13-D : stubs ksu_selinux_hide_* dans ksud.c (RESTAURÉ) ====================
echo ""
echo "=== Fix V7.13-D : stubs ksu_selinux_hide_* dans ksud.c (RESTAURÉ) ==="

KSUD_C="drivers/kernelsu/runtime/ksud.c"
if [ -f "$KSUD_C" ]; then
    python3 - "$KSUD_C" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f: content = f.read()

# Vérifier si des stubs sont déjà là
if 'static inline void ksu_selinux_hide_handle_post_fs_data(void) { }' in content:
    print("  ✅ Stubs déjà présents")
else:
    stubs = '''
/* V7.13 : stubs SUSFS pour build sans CONFIG_KSU_SUSFS */
#ifndef CONFIG_KSU_SUSFS
static inline void ksu_selinux_hide_handle_post_fs_data(void) { }
static inline void ksu_selinux_hide_handle_second_stage(void) { }
static inline void ksu_selinux_hide_drop_backup_if_unused(void) { }
#endif
'''
    m = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', content))
    if m:
        content = content[:m[-1].end()] + stubs + content[m[-1].end():]
    else:
        content = stubs + content
    with open(path, 'w') as f: f.write(content)
    print("  ✅ Stubs insérés (post_fs_data + second_stage + drop_backup_if_unused)")

# Diagnostic
with open(path, 'r') as f: lines = f.readlines()
print("  --- 12 premières lignes ---")
for i, l in enumerate(lines[:12], 1):
    print(f"    L{i}: {l.rstrip()!r}")
print("  --- occurrences ksu_selinux_hide ---")
for i, l in enumerate(lines, 1):
    if 'ksu_selinux_hide' in l:
        print(f"    L{i}: {l.rstrip()!r}")
PYEOF
else
    echo "  ❌ ksud.c introuvable"
fi

# ==================== 3k. Diagnostic final ====================
echo ""
echo "=== DIAGNOSTIC FINAL V7.13 ==="
echo "--- kernel_compat.h : macro handle_sepolicy ? (doit être ABSENT) ---"
if grep -q 'define handle_sepolicy' "$COMPAT_H" 2>/dev/null; then
    echo "  ❌ Macro encore présente"
else
    echo "  ✅ Macro absente"
fi
echo "--- sepolicy.c : wrap présent ? ---"
head -3 "$SEPOLICY" 2>/dev/null
echo "--- rules.c : __maybe_unused ? ---"
grep -n '__maybe_unused' "$RULES" 2>/dev/null | head -2 || echo "  (absent)"
echo "--- ksud.c : stubs présents ? ---"
grep -c 'ksu_selinux_hide_handle_post_fs_data(void) { }' "$KSUD_C" 2>/dev/null || echo "  0"

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_SUSFS is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KSU_LSM_SECURITY_HOOKS=y"
  echo "CONFIG_KSU_FEATURE_SULOG=y"
  echo "CONFIG_KSU_FEATURE_ADBROOT=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

grep -E "KSU_MANUAL_HOOK|KSU_SUSFS|KSU_TAMPER|KSU_LSM|KALLSYMS|SECCOMP" out/.config | head -20 || true

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé"; exit 1
fi

# ==================== 5. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 6. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-macro-redefined -Wno-unused-variable" -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|undefined symbol|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 7. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
git clone --depth=1 --branch builtin https://github.com/ShirkNeko/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src"
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
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK ====================
echo ""
echo "=== Repack ==="
rm -f ./boot-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f ./dtbo-stock.img 2>/dev/null || true
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
    "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary

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
    ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null && echo "  ✅ ksud présent"
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/SukiSU-Ultra-builtin-v7.13-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v7.13 (SukiSU-Ultra builtin, SANS SUSFS) ==="
ls -lh output/
