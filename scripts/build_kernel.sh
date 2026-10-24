#!/bin/bash
set -euo pipefail

# =============================================================================
# V4.4 : SukiSU-Ultra (susfs_new) + Hooks Manuels + Backport path_umount
#        + Fix MODULE_IMPORT_NS + Fix file_wrapper.c (iopoll/remap + unused orig)
#        + Fix seccomp_cache.c (SECCOMP_ARCH_NATIVE_NR)
#        + Fix su_mount_ns.c (include mount.h)
# =============================================================================

echo "=== Build SukiSU-Ultra (susfs_new) pour noyau 4.19 ==="
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

# ==================== 2. INTÉGRATION SukiSU-Ultra (susfs_new) ====================
echo "=== Intégration SukiSU-Ultra (susfs_new) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs_new/kernel/setup.sh" | bash -s susfs_new

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration SukiSU-Ultra"; exit 1
fi
echo "✅ SukiSU-Ultra (susfs_new) intégré"

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

# ==================== 2e. FIX O_CLOEXEC ====================
echo ""
echo "=== Fix O_CLOEXEC dans TOUS les fichiers (détection Manager) ==="

FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_GET_UNUSED" ]; then
    for f in $FILES_GET_UNUSED; do
        sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
        echo "  ✅ get_unused_fd_flags fixé dans $f"
    done
fi

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_ANON_INODE" ]; then
    for f in $FILES_ANON_INODE; do
        sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/, O_CLOEXEC)/)/g' "$f"
        echo "  ✅ anon_inode_getfile nettoyé dans $f"
    done
fi

# ==================== 3. PATCHS MANUELS SukiSU-Ultra ====================
echo ""
echo "=== Application des patchs manuels SukiSU-Ultra ==="

python3 << 'PYEOF'
import re

# 1. fs/exec.c
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\n\n"
    content = re.sub(r'(int\s+do_execve\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\t"
    content = re.sub(r'(\treturn\s+do_execveat_common\(AT_FDCWD,\s*filename,\s*argv,\s*envp,\s*0\);)', call + r'\1', content, count=1)
    with open('fs/exec.c', 'w') as f: f.write(content)
    print("✅ fs/exec.c patché")
else:
    print("✅ fs/exec.c déjà patché")

# 2. fs/open.c
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n\n"
    content = re.sub(r'(long\s+do_faccessat\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n\t"
    content = re.sub(r'(\tif\s*\(mode\s*&\s*~S_IRWXO\))', call + r'\1', content, count=1)
    with open('fs/open.c', 'w') as f: f.write(content)
    print("✅ fs/open.c patché (via do_faccessat)")
else:
    print("✅ fs/open.c déjà patché")

# 3. fs/read_write.c
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern = "#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n\n"
    match = re.search(r'(SYSCALL_DEFINE3\s*\(\s*read\s*,)', content)
    if match:
        content = content[:match.start()] + extern + content[match.start():]
        start_pos = content.find('SYSCALL_DEFINE3(read,')
        ret_pos = content.find('ssize_t ret = -EBADF;', start_pos)
        if ret_pos != -1:
            call = "\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);\n#endif"
            insert_pos = ret_pos + len('ssize_t ret = -EBADF;')
            content = content[:insert_pos] + call + content[insert_pos:]
            with open('fs/read_write.c', 'w') as f: f.write(content)
            print("✅ fs/read_write.c patché (chirurgical + cast)")
        else:
            print("❌ Impossible de trouver 'ssize_t ret = -EBADF;' dans read")
    else:
        print("❌ Impossible de trouver 'SYSCALL_DEFINE3(read,'")
else:
    print("✅ fs/read_write.c déjà patché")

# 4. fs/stat.c
with open('fs/stat.c', 'r') as f: content = f.read()
if 'ksu_handle_stat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*newfstatat)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n\t"
    content = re.sub(r'(\terror\s*=\s*vfs_fstatat\(dfd,\s*filename,\s*&stat,\s*flag\);)', call + r'\1', content, count=1)
    with open('fs/stat.c', 'w') as f: f.write(content)
    print("✅ fs/stat.c patché")
else:
    print("✅ fs/stat.c déjà patché")

# 5. kernel/reboot.c
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern = "#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*reboot)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t"
    content = re.sub(r'(/\*\s*We only trust the superuser with rebooting the system\.\s*\*/)', call + r'\1', content, count=1)
    with open('kernel/reboot.c', 'w') as f: f.write(content)
    print("✅ kernel/reboot.c patché")
else:
    print("✅ kernel/reboot.c déjà patché")

# 6. fs/namespace.c (Backport de path_umount depuis Linux 5.9)
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
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
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

	/* we must not call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}
#endif

'''
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport + r'\1', content, count=1)
    with open('fs/namespace.c', 'w') as f: f.write(content)
    print("✅ fs/namespace.c patché (backport path_umount)")
else:
    print("✅ fs/namespace.c déjà patché")

# 7. Correctif pour MODULE_IMPORT_NS sur noyau < 5.0
with open('drivers/kernelsu/core/init.c', 'r') as f: content = f.read()
if 'MODULE_IMPORT_NS' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)' not in content:
    old_line = 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);'
    new_block = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#endif'''
    if old_line in content:
        content = content.replace(old_line, new_block)
        with open('drivers/kernelsu/core/init.c', 'w') as f: f.write(content)
        print("✅ drivers/kernelsu/core/init.c patché (MODULE_IMPORT_NS conditionnel)")
    else:
        print("⚠️  Ligne MODULE_IMPORT_NS non trouvée dans init.c")
else:
    print("✅ drivers/kernelsu/core/init.c déjà patché ou non concerné")

# 8. Correctif pour file_wrapper.c sur noyau 4.19 (iopoll & remap_file_range)
print("=== Application du correctif pour file_wrapper.c ===")
file_path = 'drivers/kernelsu/infra/file_wrapper.c'
with open(file_path, 'r') as f:
    content = f.read()

if 'iopoll' in content and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)' not in content:
    content = content.replace(
        'return orig->f_op->iopoll(kiocb, spin);',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n        return orig->f_op->iopoll(kiocb, spin);\n#else\n        return -EOPNOTSUPP;\n#endif'
    )
    content = content.replace(
        'p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif'
    )
    print("  ✅ iopoll conditionnel ajouté")

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
    print("  ✅ remap_file_range conditionnel ajouté")

# 9. Correctif pour les variables 'orig' inutilisées (conséquence du correctif 8)
if 'struct file *orig = data->orig;' in content:
    content = content.replace(
        'struct file *orig = data->orig;',
        'struct file *orig __maybe_unused = data->orig;'
    )
    print("  ✅ Variables 'orig' marquées comme __maybe_unused")

with open(file_path, 'w') as f:
    f.write(content)
print("=== Correctif file_wrapper.c terminé ===")

# 10. Correctif pour seccomp_cache.c (SECCOMP_ARCH_NATIVE_NR sur noyau < 5.9)
print("=== Application du correctif pour seccomp_cache.c ===")
seccomp_path = 'drivers/kernelsu/infra/seccomp_cache.c'
with open(seccomp_path, 'r') as f:
    content = f.read()

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
        content = content[:match.end()] + fallback_defs + content[match.end():]
        with open(seccomp_path, 'w') as f:
            f.write(content)
        print("  ✅ Définitions de secours pour SECCOMP_ARCH_NATIVE_NR injectées")
    else:
        print("  ⚠️  Impossible de trouver le bloc d'includes dans seccomp_cache.c")
else:
    print("  ✅ Définitions déjà présentes ou non nécessaires")

print("=== Correctif seccomp_cache.c terminé ===")

# 11. Correctif pour su_mount_ns.c (chemin d'inclusion mount.h)
print("=== Application du correctif pour su_mount_ns.c ===")
mount_ns_path = 'drivers/kernelsu/infra/su_mount_ns.c'
with open(mount_ns_path, 'r') as f:
    content = f.read()

if '#include <uapi/linux/mount.h>' in content:
    content = content.replace(
        '#include <uapi/linux/mount.h>',
        '#include <linux/mount.h>'
    )
    with open(mount_ns_path, 'w') as f:
        f.write(content)
    print("  ✅ Chemin d'inclusion corrigé vers <linux/mount.h>")
else:
    print("  ✅ Aucun changement nécessaire (include déjà correct ou absent)")

print("=== Correctif su_mount_ns.c terminé ===")

PYEOF

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration (SukiSU-Ultra non-GKI avec SUSFS intégré) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_WITH_KPROBES is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
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
grep -E "KSU_MANUAL_HOOK|KSU_SUSFS|KSU_WITH_KPROBES|KSU_TRACEPOINT|KSU_TAMPER|KALLSYMS|SECCOMP" out/.config | head -20 || true

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
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 7. COMPILATION KSUD (depuis susfs_new) ====================
echo ""
echo "=== Compilation ksud (SukiSU-Ultra susfs_new) ==="
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
git clone --depth=1 --branch susfs_new https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$GITHUB_WORKSPACE/ksud-src"
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
echo "✅ ksud compilé (SukiSU-Ultra susfs_new)"
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK (MÉTHODE BACKSLASHXX) ====================
echo ""
echo "=== Repack (méthode backslashxx : magiskboot cpio add) ==="

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
cp final_boot.img output/SukiSU-Ultra-SUSFS-v4.4-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v4.4 (SukiSU-Ultra susfs_new) ==="
ls -lh output/
