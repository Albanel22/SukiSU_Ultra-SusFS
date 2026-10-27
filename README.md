# 🚀 SukiSU-Ultra sur Motorola One 5G Ace (Noyau 4.19 Non-GKI)

![Status](https://img.shields.io/badge/Status-Functional-brightgreen)
![Kernel](https://img.shields.io/badge/Kernel-4.19.325-blue)
![Root](https://img.shields.io/badge/Root-SukiSU--Ultra%20(Manual%20Hook)-orange)
![Device](https://img.shields.io/badge/Device-Motorola%20Kiev-red)

## 📖 Introduction

Ce dépôt contient le script de compilation et les correctifs nécessaires pour faire fonctionner **SukiSU-Ultra** (branche `builtin`) sur un noyau **Linux 4.19** (Motorola One 5G Ace / `kiev`), qui est un noyau **non-GKI** (Generic Kernel Image).

L'objectif de ce projet était de repousser les limites de compatibilité de SukiSU-Ultra, officiellement conçu pour les noyaux modernes (5.10+), afin de fournir une solution de root stable, avec injection SELinux et support des hooks manuels, sur un appareil plus ancien.

## 🏆 Le Résultat

Après **plus de 50 itérations** et une analyse approfondie des erreurs de compilation, le noyau compile avec succès et est **pleinement fonctionnel** :
*   ✅ **Root acquis** : Le Manager détecte le noyau.
*   ✅ **Hook Type : Manual Hook** : Les hooks `execve`, `faccessat` et `newfstatat` sont injectés directement dans le code source du noyau.
*   ✅ **Injection SELinux** : Le backport de `struct selinux_policy` vers `struct policydb` permet l'injection des règles de sécurité.
*   ✅ **Stabilité** : Le noyau boote sans bootloop et gère les appels système correctement.

## 🛠️ Les Défis Techniques (et leurs solutions)

Le portage de SukiSU-Ultra sur un noyau 4.19 a nécessité de contourner plusieurs incompatibilités majeures entre le code moderne du module et l'ancien noyau Motorola.

### 1. L'API SELinux (`struct selinux_policy` vs `policydb`)
SukiSU-Ultra utilise `struct selinux_policy` (introduit dans le noyau 5.10). Sur notre noyau 4.19, cette structure n'existe pas, c'est `struct selinux_ss` qui contient le `policydb`.
*   **Solution** : Nous avons modifié `rules.c` et `sepolicy.c` pour qu'ils utilisent `policydb` et adapté la fonction `get_policydb()` avec `rcu_dereference(selinux_state.ss)->policydb`.

### 2. Le Hook Type "Unknown"
Au début, le Manager affichait "Unknown" car l'option `CONFIG_KSU_HACK_ARM64_BRANCH_LINK` n'était pas reconnue par l'APK.
*   **Solution** : Abandon de cette méthode au profit de l'**injection manuelle** des appels `ksu_handle_*` directement dans `fs/exec.c`, `fs/open.c` et `fs/stat.c`.

### 3. Les Erreurs de Compilation (C89 / C99)
L'injection des hooks avant les déclarations de variables (ex: `struct kstat stat;`) provoquait des erreurs `-Werror=declaration-after-statement`.
*   **Solution** : Ajout du flag `-Wno-declaration-after-statement` dans les `KCFLAGS` pour autoriser le compilateur à utiliser les normes C99.

### 4. Les Stubs SUSFS et les includes manquants
Le code de SukiSU-Ultra appelle des fonctions SUSFS (`ksu_selinux_hide_*`) qui ne sont pas définies si SUSFS est désactivé. De plus, les en-têtes (`linux/susfs.h`) sont introuvables.
*   **Solution** : Création de stubs `static inline void ... { }` dans `runtime/ksud.c` et skip des fichiers `rules.c`/`sepolicy.c` via `ksu_main.c` lors des compilations intermédiaires.

## 📂 Fichiers du Dépôt

*   `build_sukisu_4.19.sh` : Le script de compilation complet (V7.24). Il clone le noyau LineageOS, intègre SukiSU-Ultra, applique les correctifs de compatibilité, injecte les hooks, compile `Image`, compile `ksud` et effectue le repack du `boot.img`.
*   `README.md` : Ce document.

## 🚀 Comment l'utiliser

### Prérequis
*   Une machine Linux (ou GitHub Actions).
*   Les outils de compilation croisée (`aarch64-linux-gnu-gcc`, Clang/LLVM).
*   Le `boot.img` d'origine de votre appareil (stock).

### Compilation
```bash
chmod +x build_sukisu_4.19.sh
./build_sukisu_4.19.sh
