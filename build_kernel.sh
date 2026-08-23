#!/bin/bash

# ==========================================
# Alioth AOSP Kernel Build Script
# 集成: ReSukiSU (KSU+SUSFS) + Baseband-guard + Droidspaces
# 用法: ./build_kernel.sh alioth <lto_mode> <toolchain> <patch_dir>
# 示例: ./build_kernel.sh alioth thin zyc /path/to/patch_repo
# ==========================================

set -e

# ---------------- 参数解析 ----------------
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> <lto_mode> <toolchain> <patch_dir>"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    exit 1
fi

LTO_MODE="${2:-thin}"
TOOLCHAIN_CHOICE="${3:-zyc}"
PATCH_DIR="${4:-}"

# 固定: alioth + aosp + KSU
ENABLE_KSU=1
TARGET_OS="aosp"

# ---------------- 环境配置 ----------------
KERNEL_DIR="$(pwd)"
OUT_DIR="${KERNEL_DIR}/out_${TARGET_OS}"

# 工具链路径 (由工作流通过 GITHUB_PATH 注入，这里做兼容性兜底)
case "$TOOLCHAIN_CHOICE" in
    neutron)
        TOOLCHAIN_BIN="${TC_NEUTRON_DIR:-$HOME/neutron-clang}/bin"
        ;;
    aosp)
        TOOLCHAIN_BIN="${TC_AOSP_DIR:-$HOME/aosp-clang}/bin"
        ;;
    *)
        TOOLCHAIN_BIN="${TC_ZYC_DIR:-$HOME/zyc-clang}/bin"
        ;;
esac

# 如果 PATH 里已经有 clang (工作流已配置)，优先用 PATH 里的
export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)
if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found!"
    exit 1
fi
export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found. Please check toolchain path."; exit 1; }

mkdir -p "$CCACHE_DIR"

# ---------------- KernelSU (ReSukiSU) 集成 ----------------
echo "==========================================="
echo " [*] Initializing KernelSU (ReSukiSU) Setup"
echo "==========================================="
echo "[*] Downloading and running ReSukiSU remote setup script..."
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
echo "[+] KernelSU (ReSukiSU) setup finished."
echo "==========================================="

# ---------------- Baseband-guard 集成 ----------------
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ---------------- Droidspaces 集成 ----------------
echo "==========================================="
echo " [*] Initializing Droidspaces Setup"
echo "==========================================="
if [ -n "$PATCH_DIR" ] && [ -d "$PATCH_DIR/Patches/Droidspaces" ]; then
    DROID_PATCH_DIR="$PATCH_DIR/Patches/Droidspaces"
    echo "[*] Applying Droidspaces coccinelle patches..."

    if [ -f "net/netfilter/xt_qtaguid.c" ] && [ -f "$DROID_PATCH_DIR/fix_kernel_panic_in_xt_qtaguid.cocci" ]; then
        spatch --sp-file "$DROID_PATCH_DIR/fix_kernel_panic_in_xt_qtaguid.cocci" --in-place net/netfilter/xt_qtaguid.c
        echo "[+] Applied xt_qtaguid panic fix"
    fi

    if [ -f "kernel/cgroup/cgroup.c" ] && [ -f "$DROID_PATCH_DIR/fix_restore_cgroup_file_prefix_handling.cocci" ]; then
        spatch --sp-file "$DROID_PATCH_DIR/fix_restore_cgroup_file_prefix_handling.cocci" --in-place kernel/cgroup/cgroup.c
        echo "[+] Applied cgroup prefix handling fix"
    fi
else
    echo "[!] Warning: Droidspaces patch dir not found, skipping cocci patches."
fi
echo "[+] Droidspaces setup finished."
echo "==========================================="

# ---------------- AnyKernel3 准备 ----------------
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b master --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "==========================================="

# ---------------- 编译参数 ----------------
MAKE_OPTS=(
    -j"$(nproc)"
    O="${OUT_DIR}"
    ARCH="${ARCH}"
    SUBARCH="${SUBARCH}"
    LLVM=1
    LLVM_IAS=1
    CC="ccache clang"
    HOSTCC="ccache clang"
    CROSS_COMPILE="${CROSS_COMPILE}"
    CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}"
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    READELF=llvm-readelf
    OBJSIZE=llvm-size
)

# LTO 模式
if [ "$LTO_MODE" != "none" ]; then
    MAKE_OPTS+=(LTO="$LTO_MODE")
fi

# ---------------- 清理输出目录 ----------------
echo "[*] Cleaning ${OUT_DIR}..."
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# ---------------- 生成 defconfig ----------------
echo "[*] Making defconfig: ${DEFCONFIG}..."
make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

# ---------------- 配置注入 ----------------
echo "[*] Injecting kernel configurations..."

CONFIG_ARGS=(
    -e BBG
    -e KSU
    -e THREAD_INFO_IN_TASK
    -e KSU_SUSFS
)

# Droidspaces 配置注入
if [ -n "$PATCH_DIR" ] && [ -d "$PATCH_DIR/Patches/Droidspaces" ]; then
    CONFIG_ARGS+=(
        -e PSI
        -d ANDROID_PARANOID_NETWORK
        -e USER_NS
    )
fi

scripts/config --file "${OUT_DIR}/.config" "${CONFIG_ARGS[@]}"

# Droidspaces 完整配置 merge (如果存在)
if [ -n "$PATCH_DIR" ] && [ -f "$PATCH_DIR/Patches/Droidspaces/droidspaces.config" ]; then
    echo "[*] Merging Droidspaces config..."
    scripts/kconfig/merge_config.sh -O "$OUT_DIR" -m "${OUT_DIR}/.config" "$PATCH_DIR/Patches/Droidspaces/droidspaces.config"
fi

# 重新评估依赖
echo "[*] Updating config (make olddefconfig)..."
make "${MAKE_OPTS[@]}" olddefconfig

# 打印关键配置确认
echo "[*] Verifying key configurations..."
grep -E "CONFIG_BBG|CONFIG_KSU|CONFIG_KSU_SUSFS|CONFIG_THREAD_INFO_IN_TASK|CONFIG_PSI|CONFIG_USER_NS|CONFIG_ANDROID_PARANOID_NETWORK" "${OUT_DIR}/.config" || true

# ---------------- 编译 ----------------
echo "[*] Building kernel..."
make "${MAKE_OPTS[@]}"

# ---------------- 打包 ----------------
echo "==========================================="
if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
    echo "[+] Build Successful!"
    echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

    echo "[*] Generating dtb..."
    find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUT_DIR}/arch/arm64/boot/dtb"

    echo "[*] Packaging to AnyKernel3 (aosp)..."
    rm -rf anykernel/kernels/*
    mkdir -p "anykernel/kernels/aosp/"

    cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/aosp/"
    cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/aosp/"

    if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
        cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/aosp/"
    fi

    KSU_ZIP_STR="ReSukiSU-SuSFS"
    GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
    ZIP_FILENAME="APTKernel_AOSP_${DEVICE_NAME}_${KSU_ZIP_STR}_BBG_Droid_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"

    echo "[*] Zipping $ZIP_FILENAME ..."
    pushd anykernel > /dev/null
    zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
    mv "$ZIP_FILENAME" ../
    popd > /dev/null

    echo "[+] Kernel binaries packed into: $ZIP_FILENAME"
else
    echo "[-] Build Failed. Kernel Image not found."
    exit 1
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] Build completed!"
