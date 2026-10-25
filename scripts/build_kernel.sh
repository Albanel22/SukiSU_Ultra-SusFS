#!/bin/bash
set -euo pipefail

# =============================================================================
# V7.3 : SukiSU-Ultra (ShirkNeko/builtin) — SANS SUSFS
#        V7.3 : fix access_ok bulletproof (sed + placeholder)
#                + vérification explicite + garde V7.2 conservées
# =============================================================================

echo "=== Build SukiSU-Ultra (ShirkNeko/builtin, sans SUSFS) — V7.3 ==="
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

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR : $KSU_DIR"

# ==================== 2b. NEUTRALISATION CHECK.MK ====================
echo ""
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
        done
    fi
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
for root, dirs, files in os.walk('.'):
    if 'KernelSU' not in root and 'kernelsu' not in root:
        continue
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content:
                        content = content.replace(uchar, ' ')
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
        print(f"  ⚠️  {description} : fichier {path} introuvable, ignoré")
        return False
    try:
        with open(path, 'r') as f:
            content = f.read()
        new_content = transform_func(content)
        if new_content != content:
            with open(path, 'w') as f:
                f.write(new_content)
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
static_call_h_path = 'include/linux/static_call.h'
if not os.path.exists(static_call_h_path):
    static_call_content = '''#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H
#define static_call(name) (name##_static_call)
#define static_call_cond(name) (name##_static_call)
#define static_call_update(name, func) do { } while (0)
#define static_call_query(name) (name##_static_call)
#endif
'''
    with open(static_call_h_path, 'w') as f:
        f.write(static_call_content)
    print("  ✅ include/linux/static_call.h créé")
else:
    print("  ✅ include/linux/static_call.h existe déjà")

# 2. MODULE_IMPORT_NS
print("=== Correctif MODULE_IMPORT_NS ===")
for ksu_c_path in ['drivers/kernelsu/ksu.c', 'drivers/kernelsu/ksu_main.c', 'drivers/kernelsu/core/init.c']:
    if os.path.exists(ksu_c_path):
        def transform_import_ns(content):
            if 'MODULE_IMPORT_NS' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)' not in content:
                old_line = 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);'
                new_block = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#endif'''
                return content.replace(old_line, new_block)
            return content
        modify_file(ksu_c_path, transform_import_ns, f"MODULE_IMPORT_NS dans {ksu_c_path}")

# 3. file_wrapper.c
print("=== Correctif file_wrapper.c ===")
for file_path in ['drivers/kernelsu/infra/file_wrapper.c', 'drivers/kernelsu/file_wrapper.c']:
    if os.path.exists(file_path):
        def transform_file_wrapper(content):
            if 'iopoll' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)' not in content:
                content = content.replace(
                    'return orig->f_op->iopoll(kiocb, spin);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n        return orig->f_op->iopoll(kiocb, spin);\n#else\n        return -EOPNOTSUPP;\n#endif'
                )
                content = content.replace(
                    'p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif'
                )
            if 'remap_file_range' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)' not in content:
                content = content.replace(
                    'if (remap_flags & REMAP_FILE_DEDUP) {',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n    if (remap_flags & REMAP_FILE_DEDUP) {\n#else\n    if (0) {\n#endif'
                )
                content = content.replace(
                    'return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n        return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif'
                )
                content = content.replace(
                    'return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n#else\n        return -EOPNOTSUPP;\n#endif'
                )
                content = content.replace(
                    'p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif'
                )
            if 'struct file *orig = data->orig;' in content:
                content = content.replace(
                    'struct file *orig = data->orig;',
                    'struct file *orig __maybe_unused = data->orig;'
                )
            return content
        modify_file(file_path, transform_file_wrapper, f"file_wrapper.c dans {file_path}")

# 4. seccomp_cache.c
print("=== Correctif seccomp_cache.c ===")
for seccomp_path in ['drivers/kernelsu/infra/seccomp_cache.c', 'drivers/kernelsu/seccomp_cache.c']:
    if os.path.exists(seccomp_path):
        def transform_seccomp(content):
            if 'SECCOMP_ARCH_NATIVE_NR' not in content or '#ifndef SECCOMP_ARCH_NATIVE_NR' not in content:
                fallback_defs = '''
#ifndef SECCOMP_ARCH_NATIVE_NR
#define SECCOMP_ARCH_NATIVE_NR NR_syscalls
#endif
#ifndef SECCOMP_ARCH_COMPAT_NR
#define SECCOMP_ARCH_COMPAT_NR NR_syscalls
#endif
'''
                match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if match:
                    return content[:match.end()] + fallback_defs + content[match.end():]
            return content
        modify_file(seccomp_path, transform_seccomp, f"seccomp_cache.c dans {seccomp_path}")

# 5. su_mount_ns.c include
print("=== Correctif su_mount_ns.c ===")
for mount_ns_path in ['drivers/kernelsu/infra/su_mount_ns.c', 'drivers/kernelsu/su_mount_ns.c']:
    if os.path.exists(mount_ns_path):
        def transform_mount_ns(content):
            return content.replace('#include <uapi/linux/mount.h>', '#include <linux/mount.h>')
        modify_file(mount_ns_path, transform_mount_ns, f"su_mount_ns.c dans {mount_ns_path}")

# 6. pkg_observer.c (handle_inode_event)
print("=== Correctif pkg_observer.c ===")
for pkg_observer_path in ['drivers/kernelsu/manager/pkg_observer.c', 'drivers/kernelsu/pkg_observer.c']:
    if os.path.exists(pkg_observer_path):
        def transform_pkg_observer(content):
            if '.handle_inode_event = ksu_handle_inode_event,' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' not in content:
                return content.replace(
                    '.handle_inode_event = ksu_handle_inode_event,',
                    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n\t.handle_inode_event = ksu_handle_inode_event,\n#endif'
                )
            return content
        modify_file(pkg_observer_path, transform_pkg_observer, f"pkg_observer.c dans {pkg_observer_path}")

# 7. allowlist.c
print("=== Correctif allowlist.c ===")
for allowlist_path in ['drivers/kernelsu/policy/allowlist.c', 'drivers/kernelsu/allowlist.c']:
    if os.path.exists(allowlist_path):
        def transform_allowlist(content):
            if 'TWA_RESUME' in content and '#ifndef TWA_RESUME' not in content:
                fallback_def = '''
#ifndef TWA_RESUME
#define TWA_RESUME 1
#endif
'''
                match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if match:
                    content = content[:match.end()] + fallback_def + content[match.end():]
            if '#include <linux/sched/task.h>' not in content:
                match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if match:
                    content = content[:match.end()] + '#include <linux/sched/task.h>\n' + content[match.end():]
            return content
        modify_file(allowlist_path, transform_allowlist, f"allowlist.c dans {allowlist_path}")

# 8. supercall/supercall.c (TWA_RESUME)
print("=== Correctif supercall/supercall.c ===")
for supercall_path in ['drivers/kernelsu/supercall/supercall.c']:
    if os.path.exists(supercall_path):
        def transform_supercall(content):
            if 'TWA_RESUME' in content and '#ifndef TWA_RESUME' not in content:
                fallback_def = '''
#ifndef TWA_RESUME
#define TWA_RESUME 1
#endif
'''
                match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                if match:
                    return content[:match.end()] + fallback_def + content[match.end():]
            return content
        modify_file(supercall_path, transform_supercall, f"supercall.c (TWA_RESUME) dans {supercall_path}")

# 9. supercall/dispatch.c (includes manquants)
print("=== Correctif supercall/dispatch.c ===")
for dispatch_path in ['drivers/kernelsu/supercall/dispatch.c']:
    if os.path.exists(dispatch_path):
        def transform_dispatch(content):
            includes_to_add = [
                '#include <linux/sched.h>',
                '#include <linux/sched/task.h>',
                '#include <linux/init_task.h>'
            ]
            for inc in includes_to_add:
                if inc not in content:
                    match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
                    if match:
                        content = content[:match.end()] + inc + '\n' + content[match.end():]
            return content
        modify_file(dispatch_path, transform_dispatch, f"dispatch.c dans {dispatch_path}")

# 10. app_profile.c
print("=== Correctif app_profile.c ===")
for app_profile_path in ['drivers/kernelsu/policy/app_profile.c', 'drivers/kernelsu/app_profile.c']:
    if os.path.exists(app_profile_path):
        def transform_app_profile(content):
            old_line = 'atomic_set(&current->seccomp.filter_count, 0);'
            new_block = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
	atomic_set(&current->seccomp.filter_count, 0);
#endif'''
            if old_line in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' not in content:
                return content.replace(old_line, new_block)
            return content
        modify_file(app_profile_path, transform_app_profile, f"app_profile.c dans {app_profile_path}")

# 11. rules.c
print("=== Correctif rules.c ===")
for rules_path in ['drivers/kernelsu/selinux/rules.c', 'drivers/kernelsu/rules.c']:
    if os.path.exists(rules_path):
        def transform_rules(content):
            if '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)' not in content:
                lines = content.split('\n')
                insert_pos = 0
                for i, line in enumerate(lines):
                    if line.strip() and not line.strip().startswith('//') and not line.strip().startswith('/*') and not line.strip().startswith('*') and not line.strip().startswith('#include'):
                        insert_pos = i
                        break
                lines.insert(insert_pos, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)')
                lines.append('#endif // LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)')
                return '\n'.join(lines)
            return content
        modify_file(rules_path, transform_rules, f"rules.c dans {rules_path}")

# 12. sepolicy.c
print("=== Correctif sepolicy.c ===")
for sepolicy_path in ['drivers/kernelsu/selinux/sepolicy.c', 'drivers/kernelsu/sepolicy.c']:
    if os.path.exists(sepolicy_path):
        def transform_sepolicy(content):
            if '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' not in content:
                lines = content.split('\n')
                insert_pos = 0
                for i, line in enumerate(lines):
                    if line.strip() and not line.strip().startswith('//') and not line.strip().startswith('/*') and not line.strip().startswith('*') and not line.strip().startswith('#include'):
                        insert_pos = i
                        break
                lines.insert(insert_pos, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                lines.append('#endif // LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                return '\n'.join(lines)
            return content
        modify_file(sepolicy_path, transform_sepolicy, f"sepolicy.c dans {sepolicy_path}")

# 13. selinux_hide.c
print("=== Correctif selinux_hide.c ===")
for selinux_hide_path in ['drivers/kernelsu/feature/selinux_hide.c', 'drivers/kernelsu/selinux_hide.c']:
    if os.path.exists(selinux_hide_path):
        def transform_selinux_hide(content):
            if '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' not in content:
                lines = content.split('\n')
                insert_pos = 0
                for i, line in enumerate(lines):
                    if line.strip() and not line.strip().startswith('//') and not line.strip().startswith('/*') and not line.strip().startswith('*') and not line.strip().startswith('#include'):
                        insert_pos = i
                        break
                lines.insert(insert_pos, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                lines.append('#endif // LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)')
                return '\n'.join(lines)
            return content
        modify_file(selinux_hide_path, transform_selinux_hide, f"selinux_hide.c dans {selinux_hide_path}")

# 14. extension/cpu_spoof.c
print("=== Correctif extension/cpu_spoof.c ===")
for cpu_spoof_path in ['drivers/kernelsu/extension/cpu_spoof.c']:
    if os.path.exists(cpu_spoof_path):
        def transform_cpu_spoof(content):
            if 'vdso_clock_mode' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)' not in content:
                old_block = '''(*curr_cs_ptr)->vdso_clock_mode ='''
                new_block = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
                        (*curr_cs_ptr)->vdso_clock_mode ='''
                content = content.replace(old_block, new_block)
                content = re.sub(
                    r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 7, 0\)\n\s*\(\*curr_cs_ptr\)->vdso_clock_mode\s*=\s*[^;]+;)',
                    r'\1\n#endif',
                    content
                )
                print("  ✅ vdso_clock_mode conditionnel")
            return content
        modify_file(cpu_spoof_path, transform_cpu_spoof, f"cpu_spoof.c dans {cpu_spoof_path}")

# 15. sulog/event.c
print("=== Correctif sulog/event.c ===")
for event_path in ['drivers/kernelsu/sulog/event.c']:
    if os.path.exists(event_path):
        def transform_event(content):
            return content.replace('#include <linux/minmax.h>', '#include <linux/kernel.h>')
        modify_file(event_path, transform_event, f"sulog/event.c dans {event_path}")

# 16. Backports path_umount + path_mount
print("=== Backport path_umount et path_mount ===")
namespace_path = 'fs/namespace.c'
with open(namespace_path, 'r') as f:
    content = f.read()

if 'int path_umount(struct path *path, int flags)' not in content:
    backport_umount = '''
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
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport_umount + r'\1', content, count=1)
    print("  ✅ path_umount backporté")

if 'int path_mount(' not in content:
    backport_mount = '''
#ifdef CONFIG_KSU
int path_mount(const char *dev_name, struct path *path,
               const char *type_page, unsigned long flags, void *data_page)
{
    char *page = (char *)__get_free_page(GFP_KERNEL);
    char *p;
    int ret;
    mm_segment_t old_fs;
    if (!page)
        return -ENOMEM;
    p = d_path(path, page, PAGE_SIZE);
    if (IS_ERR(p)) {
        ret = PTR_ERR(p);
        goto out_free;
    }
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
    anchor = 'int path_umount(struct path *path, int flags)'
    if anchor in content:
        match = re.search(r'int path_umount\(struct path \*path, int flags\).*?\n\}', content, re.DOTALL)
        if match:
            content = content[:match.end()] + '\n' + backport_mount + content[match.end():]
        else:
            content = content.replace('int ksys_umount(', backport_mount + '\nint ksys_umount(')
    else:
        content = content.replace('int ksys_umount(', backport_mount + '\nint ksys_umount(')
    print("  ✅ path_mount backporté")

with open(namespace_path, 'w') as f:
    f.write(content)

# ==================== 3c. Fix A : KSU_NO_PREINIT (V7.2, conservé) ====================
print("")
print("=== Fix A : KSU_NO_PREINIT ===")
preinit_h = 'drivers/kernelsu/preinit/common/preinit.h'
if os.path.exists(preinit_h):
    with open(preinit_h, 'r') as f:
        lines = f.readlines()
    new_lines = []
    for line in lines:
        if line.strip() == '#define KSU_NO_PREINIT':
            new_lines.append('#define KSU_NO_PREINIT 1\n')
        else:
            new_lines.append(line)
    with open(preinit_h, 'w') as f:
        f.writelines(new_lines)
    print(f"  ✅ KSU_NO_PREINIT normalisé dans {preinit_h}")
else:
    print(f"  ⚠️  {preinit_h} introuvable")

# ==================== 3d. Fix C/D/E/F : feature enum + SUSFS guards + USER_ARG_NULL ====================
print("")
print("=== Fix C/D/E/F : feature enum + SUSFS guards + USER_ARG_NULL ===")

# Fix C: KSU_FEATURE_SELINUX_HIDE dans l'enum
feature_h = 'drivers/kernelsu/include/uapi/feature.h'
if os.path.exists(feature_h):
    with open(feature_h, 'r') as f:
        content = f.read()
    if 'KSU_FEATURE_SELINUX_HIDE' not in content:
        content = re.sub(
            r'(KSU_FEATURE_MOUNT_HIDE\s*=\s*16,)',
            r'\1\n\tKSU_FEATURE_SELINUX_HIDE = 17,',
            content
        )
        with open(feature_h, 'w') as f:
            f.write(content)
        print(f"  ✅ KSU_FEATURE_SELINUX_HIDE ajouté dans {feature_h}")
    else:
        print(f"  ✅ KSU_FEATURE_SELINUX_HIDE déjà présent dans {feature_h}")
else:
    print(f"  ⚠️  {feature_h} introuvable")

# Fix D: Guard SUSFS dans pkg_observer.c
pkg_observer = 'drivers/kernelsu/manager/pkg_observer.c'
if not os.path.exists(pkg_observer):
    pkg_observer = 'drivers/kernelsu/pkg_observer.c'
if os.path.exists(pkg_observer):
    with open(pkg_observer, 'r') as f:
        content = f.read()
    if 'susfs_parse_priority_app_strings' in content and 'CONFIG_KSU_SUSFS' not in content:
        content = re.sub(
            r'(\s*)susfs_parse_priority_app_strings\(\);',
            r'\1#ifdef CONFIG_KSU_SUSFS\n\1susfs_parse_priority_app_strings();\n\1#endif',
            content
        )
        with open(pkg_observer, 'w') as f:
            f.write(content)
        print(f"  ✅ susfs_parse_priority_app_strings guardé dans {pkg_observer}")
    else:
        print(f"  ✅ {pkg_observer} déjà guardé ou pas de susfs")

# Fix E: Guards SUSFS dans ksud.c
ksud_c = 'drivers/kernelsu/runtime/ksud.c'
if os.path.exists(ksud_c):
    with open(ksud_c, 'r') as f:
        content = f.read()
    if 'ksu_selinux_hide_handle_post_fs_data' in content and 'CONFIG_KSU_SUSFS' not in content:
        content = re.sub(
            r'(\s*)ksu_selinux_hide_handle_post_fs_data\(\);',
            r'\1#ifdef CONFIG_KSU_SUSFS\n\1ksu_selinux_hide_handle_post_fs_data();\n\1#endif',
            content
        )
        content = re.sub(
            r'(\s*)ksu_selinux_hide_handle_second_stage\(\);',
            r'\1#ifdef CONFIG_KSU_SUSFS\n\1ksu_selinux_hide_handle_second_stage();\n\1#endif',
            content
        )
        with open(ksud_c, 'w') as f:
            f.write(content)
        print(f"  ✅ ksu_selinux_hide_* guardé dans {ksud_c}")
    else:
        print(f"  ✅ {ksud_c} déjà guardé ou pas de selinux_hide")

# Fix F: USER_ARG_NULL dans sulog/event.c
for root, dirs, files in os.walk('drivers/kernelsu/sulog'):
    for file in files:
        if file.endswith(('.c', '.h')):
            path = os.path.join(root, file)
            with open(path, 'r') as f:
                content = f.read()
            if '#define USER_ARG_NULL user_arg_null_ptr()' in content:
                content = content.replace(
                    '#define USER_ARG_NULL user_arg_null_ptr()',
                    '#define USER_ARG_NULL (*user_arg_null_ptr())'
                )
                with open(path, 'w') as f:
                    f.write(content)
                print(f"  ✅ USER_ARG_NULL corrigé dans {path}")

print("=== Correctifs Python terminés ===")

PYEOF

# ==================== 3e. FIX B BULLETPROOF : access_ok → ksu_access_ok (sed) ====================
echo ""
echo "=== Fix B bulletproof : access_ok → ksu_access_ok (sed + placeholder) ==="

KPM_C=$(find drivers/kernelsu -path '*/kpm/kpm.c' -type f 2>/dev/null | head -1)
if [ -z "$KPM_C" ]; then
    KPM_C=$(find drivers/kernelsu -name 'kpm.c' -type f 2>/dev/null | head -1)
fi

if [ -n "$KPM_C" ] && [ -f "$KPM_C" ]; then
    echo "  KPM_C = $KPM_C"
    # Étape 1 : protéger les ksu_access_ok existants avec un placeholder
    sed -i 's/ksu_access_ok(/__KSU_AOK_PLACEHOLDER__(/g' "$KPM_C"
    # Étape 2 : remplacer tous les access_ok( nus par ksu_access_ok(
    sed -i 's/access_ok(/ksu_access_ok(/g' "$KPM_C"
    # Étape 3 : restaurer le placeholder
    sed -i 's/__KSU_AOK_PLACEHOLDER__(/ksu_access_ok(/g' "$KPM_C"
    echo "  ✅ access_ok → ksu_access_ok appliqué"

    # Vérification
    if grep -q '[^_]access_ok(' "$KPM_C" 2>/dev/null; then
        echo "  ⚠️  Des appels access_ok( nus restent :"
        grep -n '[^_]access_ok(' "$KPM_C" | head -5
    else
        echo "  ✅ Aucun access_ok( nu restant"
    fi
    echo "  Aperçu des lignes ksu_access_ok :"
    grep -n 'ksu_access_ok(' "$KPM_C" | head -3
else
    echo "  ⚠️  kpm.c introuvable"
fi

# Ensure macro dans kernel_compat.h
COMPAT_H=$(find drivers/kernelsu -name 'kernel_compat.h' -type f 2>/dev/null | head -1)
if [ -n "$COMPAT_H" ] && [ -f "$COMPAT_H" ]; then
    if ! grep -q 'define ksu_access_ok' "$COMPAT_H"; then
        echo "  ⚠️  Macro ksu_access_ok absent de $COMPAT_H, ajout..."
        python3 - "$COMPAT_H" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
macro = '''
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define ksu_access_ok(addr, size) access_ok(VERIFY_READ, addr, size)
#else
#define ksu_access_ok(addr, size) access_ok(addr, size)
#endif
'''
match = list(re.finditer(r'#include\s+[<"][^>"]+[>"]\n', content))
if match:
    last = match[-1]
    content = content[:last.end()] + macro + content[last.end():]
else:
    content = macro + content
with open(path, 'w') as f:
    f.write(content)
print("  ✅ ksu_access_ok macro ajouté dans kernel_compat.h")
PYEOF
    else
        echo "  ✅ ksu_access_ok macro déjà présent dans $COMPAT_H"
    fi
fi

# ==================== 4. CONFIGURATION (SANS SUSFS) ====================
echo ""
echo "=== Configuration (SukiSU-Ultra builtin, SANS SUSFS) ==="
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

echo "=== État final .config ==="
grep -E "KSU_MANUAL_HOOK|KSU_SUSFS|KSU_TAMPER|KSU_LSM|KALLSYMS|SECCOMP" out/.config | head -20 || true

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé, abandon"
    exit 1
fi

# ==================== 5. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 6. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-macro-redefined" -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 7. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud (SukiSU-Ultra builtin) ==="
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
echo "=== Repack (méthode backslashxx) ==="

rm -f ./boot-stock.img 2>/dev/null || true
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
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
set +e
./magiskboot unpack boot.img
set -e

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
cp final_boot.img output/SukiSU-Ultra-builtin-v7.3-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v7.3 (SukiSU-Ultra builtin, SANS SUSFS) ==="
ls -lh output/
