#!/usr/bin/env bash

# Active versions:
# - AWS-LC: 1.72.1
# - Brotli: 1.2.0
# - CRC32C: 1.1.2
# - Hiredis: 1.3.0
# - LevelDB: 1.23
# - LLVM: 21.1.2
# - LZ4: 1.10.0
# - Mimalloc: 3.1.5
# - Musl: 1.2.5 (patched)
# - OpenSSL: 3.6.0
# - Snappy: 1.2.2
# - SQLCipher: 4.11.0
# - SQLite: 3.51.0
# - Zlib-Ng: 2.3.1
# - Zlib: Cloudflare Zlib @gcc.amd64
# - Zstd: d462f691ba6a53bd17de492656af7878c73288c8

# Eventual goal:
# LLVM_PROJECTS="clang;clang-tools-extra;lldb;lld;bolt"

set -e -o pipefail

## Components.
BUILD_AWS_LC=${BUILD_AWS_LC:-yes}
BUILD_BROTLI=${BUILD_BROTLI:-yes}
BUILD_CAPNP=${BUILD_CAPNP:-no}
BUILD_CRC32C=${BUILD_CRC32C:-yes}
BUILD_HIREDIS=${BUILD_HIREDIS:-yes}
BUILD_LEVELDB=${BUILD_LEVELDB:-yes}
BUILD_LLVM=${BUILD_LLVM:-yes}
BUILD_OPENSSL=${BUILD_OPENSSL:-yes}
BUILD_SNAPPY=${BUILD_SNAPPY:-yes}
BUILD_SQLCIPHER=${BUILD_SQLCIPHER:-no}
BUILD_SQLITE=${BUILD_SQLITE:-no}
BUILD_STAGE2=${BUILD_STAGE2:-yes}
BUILD_ZLIB_NG=${BUILD_ZLIB_NG:-yes}
BUILD_ZLIB=${BUILD_ZLIB:-yes}
BUILD_ZSTD=${BUILD_ZSTD:-yes}
BUILD_LZ4=${BUILD_LZ4:-yes}

## Settings.
RELEASE=${RELEASE:-no}
HARDEN=${HARDEN:-yes}
SECURE=${SECURE:-OFF}
GUARDED=${GUARDED:-OFF}
CFI=${CFI:-no}
MPK=${MPK:-no}
LLVM_PROJECTS=${LLVM_PROJECTS:-"clang;lld"}
LLVM_RUNTIMES=${LLVM_RUNTIMES:-"compiler-rt"}
PREFER_COMPILER_FAMILY=${PREFER_COMPILER_FAMILY:-gcc}

## Advanced settings.
USE_MUSL_CROSSMAKE=${USE_MUSL_CROSSMAKE:-yes}
USE_SCCACHE=${USE_SCCACHE:-yes}
USE_LTO=${USE_LTO:-no}
USE_WIDE_VECTORS=${USE_WIDE_VECTORS:-no}
CLEAN_BEFORE_BUILD=${CLEAN_BEFORE_BUILD:-yes}
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
MAKE_SYMLINK=${MAKE_SYMLINK:-no}

# LTO for musl itself - requires clang and enables cross-language LTO with Rust
# When enabled, musl is built with clang -flto=thin, producing LLVM bitcode
# that can be optimized together with Rust code at link time.
MUSL_USE_LTO=${MUSL_USE_LTO:-no}

# Apply the unified Elide cflags profile (cflags/ submodule) to runtime
# library builds (zlib, openssl, sqlite, …) for flag uniformity across the
# downstream pipeline. The profile is layered: cflags/<rollup> +
# cflags.local/<rollup>. Requires PREFER_COMPILER_FAMILY=clang.
#
# Only the compile rollup (base → os → os-arch) is applied; the *-bin
# (final-link) layer is intentionally not used here — its --fatal-warnings
# and -z defs flags turn legitimate warnings / runtime-resolved undefined
# symbols into build failures for these deps.
USE_CFLAGS_PROFILE=${USE_CFLAGS_PROFILE:-yes}

MODERN_X86_64_ARCH_TARGET=x86-64-v3
MODERN_X86_64_ARCH_TUNE=znver3
MODERN_AARCH64_ARCH_TARGET=armv8.4-a+crypto+crc
MODERN_AARCH64_ARCH_TUNE=neoverse-v1

JOBS=$(nproc)
ARCH_FLAVOR=${ARCH_FLAVOR:-amd64}
ROOT_DIR=$PWD

MUSL_VERSION=1.2.5
SYSROOT_PREFIX="$ROOT_DIR/$MUSL_VERSION"

GCC_LTOFLAGS="-flto -ffat-lto-objects"
CLANG_LTOFLAGS="-flto=thin"

OPT_CFLAGS_BASE="-ffunction-sections -fdata-sections"
OPT_LDFLAGS_BASE="-Wl,--gc-sections"

unset CC
unset CXX
unset CFLAGS
unset CXXFLAGS
unset LDFLAGS

source ./vars.sh || echo "No vars; using defaults."

# Validate sccache availability if requested
if [ "$USE_SCCACHE" = "yes" ]; then
  SCCACHE_BIN=$(which sccache 2>/dev/null || true)
  if [ -z "$SCCACHE_BIN" ]; then
    echo "WARNING: USE_SCCACHE=yes but sccache not found. Disabling sccache."
    USE_SCCACHE=no
  fi
fi

# Set up initial compiler family with full paths
if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
  LTO_CFLAGS="$CLANG_LTOFLAGS"
  export CC=$(which clang)
  # Try to find clang++, or derive from clang path
  export CXX=$(which clang++ 2>/dev/null)
  if [ -z "$CXX" ] && [ -n "$CC" ]; then
    # Derive clang++ path from clang (e.g., /usr/bin/clang -> /usr/bin/clang++)
    CXX="${CC}++"
    if [ ! -x "$CXX" ]; then
      # Try clang++ in same directory
      CXX="$(dirname "$CC")/clang++"
    fi
  fi
  export LD=$(which ld.lld 2>/dev/null || which ld)
  export AR=$(which llvm-ar 2>/dev/null || which ar)
  export NM=$(which llvm-nm 2>/dev/null || which nm)
  export RANLIB=$(which llvm-ranlib 2>/dev/null || which ranlib)
else
  LTO_CFLAGS="$GCC_LTOFLAGS"
  export CC=$(which gcc)
  export CXX=$(which g++)
  export LD=$(which ld)
  export AR=$(which gcc-ar 2>/dev/null || which ar)
  export NM=$(which gcc-nm 2>/dev/null || which nm)
  export RANLIB=$(which gcc-ranlib 2>/dev/null || which ranlib)
fi

# Verify critical tools exist
if [ -z "$CC" ] || [ ! -x "$CC" ]; then
  echo "ERROR: C compiler not found: $PREFER_COMPILER_FAMILY"
  exit 1
fi
if [ -z "$CXX" ] || [ ! -x "$CXX" ]; then
  echo "ERROR: C++ compiler not found: $PREFER_COMPILER_FAMILY"
  exit 1
fi
if [ -z "$AR" ] || [ ! -x "$AR" ]; then
  echo "ERROR: Archiver (ar) not found"
  exit 1
fi

# Validate MUSL_USE_LTO requirements
if [ "$MUSL_USE_LTO" = "yes" ]; then
  if [ "$PREFER_COMPILER_FAMILY" != "clang" ]; then
    echo "ERROR: MUSL_USE_LTO=yes requires PREFER_COMPILER_FAMILY=clang"
    echo "Cross-language LTO with Rust requires LLVM bitcode (clang -flto=thin)"
    exit 1
  fi
  # Verify llvm-ar is available (required for LTO bitcode in archives)
  if ! which llvm-ar >/dev/null 2>&1; then
    echo "ERROR: MUSL_USE_LTO=yes requires llvm-ar for LTO bitcode preservation"
    exit 1
  fi
fi

echo "Using bootstrap compiler: $CC"
echo "Using C++ compiler: $CXX"
echo "Using archiver: $AR"

echo "-----------------------------------------------"
echo "Musl toolchain:"
echo "BUILD_AWS_LC=$BUILD_AWS_LC"
echo "BUILD_BROTLI=$BUILD_BROTLI"
echo "BUILD_CAPNP=$BUILD_CAPNP"
echo "BUILD_CRC32C=$BUILD_CRC32C"
echo "BUILD_HIREDIS=$BUILD_HIREDIS"
echo "BUILD_LEVELDB=$BUILD_LEVELDB"
echo "BUILD_LLVM=$BUILD_LLVM"
echo "BUILD_PROPELLER=$BUILD_PROPELLER"
echo "BUILD_OPENSSL=$BUILD_OPENSSL"
echo "BUILD_SNAPPY=$BUILD_SNAPPY"
echo "BUILD_SQLCIPHER=$BUILD_SQLCIPHER"
echo "BUILD_SQLITE=$BUILD_SQLITE"
echo "BUILD_STAGE2=$BUILD_STAGE2"
echo "BUILD_ZLIB_NG=$BUILD_ZLIB_NG"
echo "BUILD_ZLIB=$BUILD_ZLIB"
echo "BUILD_ZSTD=$BUILD_ZSTD"
echo "BUILD_LZ4=$BUILD_LZ4"
echo ""
echo "MUSL_USE_MIMALLOC=$MUSL_USE_MIMALLOC"
echo "MUSL_USE_LTO=$MUSL_USE_LTO"
echo ""
echo "RELEASE=$RELEASE"
echo "HARDEN=$HARDEN"
echo "SECURE=$SECURE"
echo "GUARDED=$GUARDED"
echo "CFI=$CFI"
echo "MPK=$MPK"
echo "LLVM_PROJECTS=$LLVM_PROJECTS"
echo ""
echo "USE_MUSL_CROSSMAKE=$USE_MUSL_CROSSMAKE"
echo "USE_SCCACHE=$USE_SCCACHE"
echo "USE_LTO=$USE_LTO"
echo "USE_WIDE_VECTORS=$USE_WIDE_VECTORS"
echo "CLEAN_BEFORE_BUILD=$CLEAN_BEFORE_BUILD"
echo "MUSL_USE_MIMALLOC=$MUSL_USE_MIMALLOC"
echo "MAKE_SYMLINK=$MAKE_SYMLINK"
echo "ARCH_FLAVOR=$ARCH_FLAVOR"
echo "JOBS=$JOBS"
echo "PREFER_COMPILER_FAMILY=$PREFER_COMPILER_FAMILY"
echo "-----------------------------------------------"
echo "Building starting in 3 seconds..."
sleep 1
echo "2..."
sleep 1
echo "1..."
sleep 1

echo "Symlinking 'latest'..."
if [ "$MAKE_SYMLINK" != "yes" ]; then
  echo "Skipping symlink creation as per configuration."
else
  echo "Creating symlink 'latest' -> '$MUSL_VERSION'"
  rm -fv latest
  ln -s "$MUSL_VERSION" latest
fi

set -e -o pipefail -x

# if musl version is empty, fail
if [ -z "$MUSL_VERSION" ]; then
  echo "MUSL_VERSION is not set. Exiting."
  exit 1
fi
if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
  echo "Cleaning previous build at $MUSL_VERSION ..."
  rm -fr "$MUSL_VERSION"
fi

mkdir -p "$MUSL_VERSION/lib" "$MUSL_VERSION/include" "$MUSL_VERSION/bin"

mkdir -p "./$MUSL_VERSION/include/linux"
mkdir -p "./$MUSL_VERSION/include/asm"
mkdir -p "./$MUSL_VERSION/include/asm-generic"

# Copy kernel headers (adjust paths for Ubuntu's multiarch layout)
cp -r /usr/include/linux/* "./$MUSL_VERSION/include/linux/"
cp -r /usr/include/asm-generic/* "./$MUSL_VERSION/include/asm-generic/"

# Base optimization flags (no -O level here, added separately)
OPT_CFLAGS="$OPT_CFLAGS_BASE -fomit-frame-pointer"
OPT_LDFLAGS="$OPT_LDFLAGS_BASE"

# Security flags - some differ between compilers
# Note: _FORTIFY_SOURCE is NOT used because it requires glibc's fortified
# function implementations (__fprintf_chk, __printf_chk, etc.) which musl
# does not provide. We explicitly undefine it in case system defaults set it.
#
# For clang builds, we keep flags minimal since these are build tools.
# Hardening flags matter more for final binaries built WITH these tools.

if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
  # Minimal flags for build tools
  SECURITY_CFLAGS="-U_FORTIFY_SOURCE"
  # -Wno-mismatched-tags: struct vs class forward decl only matters for MSVC ABI (C++ only)
  SECURITY_CXXFLAGS="-Wno-mismatched-tags"
  SECURITY_LDFLAGS=""
  CMAKE_C_COMPILER="$CC"
  CMAKE_CXX_COMPILER="$CXX"
else
  # GCC gets full hardening since it's typically building final artifacts
  SECURITY_CFLAGS="-U_FORTIFY_SOURCE -fno-plt -fstack-protector-strong -fstack-clash-protection -fno-semantic-interposition -Wa,--noexecstack"
  SECURITY_CXXFLAGS=""
  SECURITY_LDFLAGS="-Wl,-z,relro,-z,now,-z,separate-code"
  CMAKE_C_COMPILER="$CC"
  CMAKE_CXX_COMPILER="$CXX"
fi

# Architecture-specific configuration
if [ "$ARCH_FLAVOR" = "amd64" ]; then
  ARCH_FLAVOR="x86_64"
  MUSL_TARGET="x86_64-linux-musl"
  LINUX_ARCH_DIR="x86_64-linux-musl"
  C_TARGET_ARCH=${C_TARGET_ARCH:-$MODERN_X86_64_ARCH_TARGET}
  C_TARGET_TUNE=${C_TARGET_TUNE:-$MODERN_X86_64_ARCH_TUNE}
  if [ "$USE_WIDE_VECTORS" = "yes" ]; then
    OPT_CFLAGS="$OPT_CFLAGS -mavx512f -mavx512bw -mavx512dq -mavx512vl"
  fi
  # CFI handling - only add one level of protection
  if [ "$CFI" = "yes" ]; then
    SECURITY_CFLAGS="$SECURITY_CFLAGS -fcf-protection=full"
    if [ "$MPK" = "yes" ]; then
      SECURITY_CFLAGS="$SECURITY_CFLAGS -mpku"
    fi
  else
    SECURITY_CFLAGS="$SECURITY_CFLAGS -fcf-protection=branch"
  fi
  # Copy asm headers from x86_64-linux-gnu, since musl does not have them
  cp -r /usr/include/x86_64-linux-gnu/asm/* "./$MUSL_VERSION/include/asm/"
elif [ "$ARCH_FLAVOR" = "arm64" ]; then
  ARCH_FLAVOR="aarch64"
  MUSL_TARGET="$ARCH_FLAVOR-linux-musl"
  LINUX_ARCH_DIR="$ARCH_FLAVOR-linux-musl"
  SECURITY_CFLAGS="$SECURITY_CFLAGS -mbranch-protection=standard"
  C_TARGET_ARCH=${C_TARGET_ARCH:-$MODERN_AARCH64_ARCH_TARGET}
  C_TARGET_TUNE=${C_TARGET_TUNE:-$MODERN_AARCH64_ARCH_TUNE}
  if [ "$USE_WIDE_VECTORS" = "yes" ]; then
    C_TARGET_ARCH="$C_TARGET_ARCH+sve"
    OPT_CFLAGS="$OPT_CFLAGS -msve-vector-bits=256"
  fi
  cp -r /usr/include/$ARCH_FLAVOR-linux-gnu/asm/* "./$MUSL_VERSION/include/asm/"
else
  echo "Unsupported ARCH_FLAVOR: $ARCH_FLAVOR"
  exit 1
fi

# Common flags for all builds - single -O3 here
# Note: CLANG_TARGET_FLAGS is NOT included in global exports because:
# 1. The GCC toolchain doesn't exist until musl-cross-make completes
# 2. gcc doesn't understand --gcc-toolchain
# Instead, CLANG_TARGET_FLAGS is used explicitly in run_cmake() and specific builds
BASE_CFLAGS="-I$SYSROOT_PREFIX/include -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3"
BASE_CXXFLAGS="$BASE_CFLAGS $SECURITY_CXXFLAGS"
BASE_LDFLAGS_PATHS="-L$SYSROOT_PREFIX/lib -L$SYSROOT_PREFIX/lib64"

# Clang-specific flags for targeting musl (set after toolchain is built)
# --target tells clang the target triple (needed to find GCC runtime in lib/gcc/$target/$version/)
# --sysroot prevents searching glibc headers
# --gcc-toolchain finds GCC's crtbegin/crtend and libgcc in the musl sysroot
# -fuse-ld=lld uses LLVM's linker (link-time only, causes unused arg warning during compilation)
if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
  # Compile-time flags (no linker-specific options)
  CLANG_TARGET_FLAGS="--target=$MUSL_TARGET --sysroot=$SYSROOT_PREFIX --gcc-toolchain=$SYSROOT_PREFIX"
  # Link-time flags (includes -fuse-ld=lld)
  CLANG_LINK_FLAGS="$CLANG_TARGET_FLAGS -fuse-ld=lld"
else
  CLANG_TARGET_FLAGS=""
  CLANG_LINK_FLAGS=""
fi

# ---------------------------------------------------------------------------
# Unified runtime cflags profile (cflags/ submodule + cflags.local overlay)
# ---------------------------------------------------------------------------
# Produces the rolled-up flag set used by every runtime-library build below
# (zlib, zstd, openssl, sqlite, …). The toolchain layer (musl libc, LLVM,
# Propeller, mimalloc) is intentionally NOT covered here; those have their
# own carefully tuned flag sets and the cflags profile would either no-op or
# break them.
#
# Resolution order (last flag wins per clang/gcc precedence):
#   1. $CLANG_TARGET_FLAGS — pins the build to musl regardless of which
#      clang gets invoked (defends against system-glibc clang leaking in).
#   2. cflags/<rollup>     — upstream profile (Elide-wide).
#   3. cflags.local/<rollup> — local suppressions for third-party noise.
#   4. -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE — user override of the
#      profile's hardcoded x86-64-v3 / znver3 baseline.
#
# Only the compile rollup is applied — the *-bin layer is excluded entirely
# (its --fatal-warnings / -z defs would break legitimate runtime-resolved
# symbols and warnings in our deps).

# Map the build-script's already-canonicalized arch (x86_64/aarch64) back to
# the cflags submodule's naming (amd64/arm64).
cflags_arch_name() {
  case "$ARCH_FLAVOR" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "ERROR: cflags profile does not support ARCH_FLAVOR=$ARCH_FLAVOR" >&2; return 1 ;;
  esac
}

# Read a flag file: strip end-of-line comments + blank lines, collapse to
# a single space-separated token list. Identical semantics to the upstream
# cflags.sh resolver so cflags.local files behave the same way.
read_flag_file() {
  local f="$1"
  if [ -f "$f" ]; then
    sed -e 's/#.*$//' -e 's/[[:space:]]\{1,\}$//' "$f" \
      | grep -v '^[[:space:]]*$' \
      | xargs || true
  fi
}

# Resolve the runtime cflags profile (compile rollup only:
# base → os → os-arch, then cflags.local overlay in the same chain order).
resolve_runtime_profile() {
  local cflags_arch
  cflags_arch="$(cflags_arch_name)" || return 1

  local upstream
  upstream="$("$ROOT_DIR/cflags/cli/cflags.sh" linux "$cflags_arch")"

  local local_files=(
    "$ROOT_DIR/cflags.local/base.txt"
    "$ROOT_DIR/cflags.local/linux.txt"
    "$ROOT_DIR/cflags.local/linux-${cflags_arch}.txt"
  )
  local extra=""
  for f in "${local_files[@]}"; do
    local content
    content="$(read_flag_file "$f")"
    [ -n "$content" ] && extra="$extra $content"
  done
  echo "$upstream$extra"
}

# Populate profile var once at startup. Empty when disabled, which makes
# the runtime helpers fall through to the legacy code path automatically.
RUNTIME_PROFILE_CFLAGS=""
if [ "$USE_CFLAGS_PROFILE" = "yes" ]; then
  if [ "$PREFER_COMPILER_FAMILY" != "clang" ]; then
    echo "ERROR: USE_CFLAGS_PROFILE=yes requires PREFER_COMPILER_FAMILY=clang"
    echo "       (the upstream profile uses clang-only flags like -Qunused-arguments)"
    exit 1
  fi
  if [ ! -x "$ROOT_DIR/cflags/cli/cflags.sh" ]; then
    echo "ERROR: cflags submodule not initialized (cflags/cli/cflags.sh missing)."
    echo "       Run: git submodule update --init cflags"
    exit 1
  fi
  RUNTIME_PROFILE_CFLAGS="$(resolve_runtime_profile)"
  echo "Runtime cflags profile: enabled (linux/$(cflags_arch_name))"
fi

# Build the final compile/link flag strings for runtime-library builds.
# Used by run_cmake_runtime and the autotools call sites below.
runtime_cc_flags() {
  if [ "$USE_CFLAGS_PROFILE" = "yes" ]; then
    # CLANG_TARGET_FLAGS first → pins to musl. Profile next. Then arch
    # overrides (last-wins) so C_TARGET_ARCH/TUNE env still work.
    echo "$CLANG_TARGET_FLAGS $RUNTIME_PROFILE_CFLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE"
  else
    # Legacy path identical to what each call site used to inline.
    echo "$CLANG_TARGET_FLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3"
  fi
}
runtime_cxx_flags() {
  if [ "$USE_CFLAGS_PROFILE" = "yes" ]; then
    echo "$CLANG_TARGET_FLAGS $RUNTIME_PROFILE_CFLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE"
  else
    echo "$CLANG_TARGET_FLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS $SECURITY_CXXFLAGS -O3"
  fi
}
runtime_ld_flags() {
  if [ "$USE_CFLAGS_PROFILE" = "yes" ]; then
    # Reuse the compile profile so the linker still sees -fuse-ld=lld and
    # -Wl,-z,* hardening, but without the aggressive bin-only flags
    # (--fatal-warnings, -z defs, --gc-sections) that break our deps.
    echo "$CLANG_LINK_FLAGS $RUNTIME_PROFILE_CFLAGS -L$SYSROOT_PREFIX/lib"
  else
    echo "$CLANG_LINK_FLAGS -L$SYSROOT_PREFIX/lib"
  fi
}

# For now, use base flags without clang sysroot (toolchain not built yet)
COMMON_CFLAGS="$BASE_CFLAGS"
COMMON_CXXFLAGS="$BASE_CXXFLAGS"
COMMON_LDFLAGS_PATHS="$BASE_LDFLAGS_PATHS"
# Full LDFLAGS with security hardening - use only for explicit link commands
COMMON_LDFLAGS="$COMMON_LDFLAGS_PATHS $OPT_LDFLAGS $SECURITY_LDFLAGS -static"

if [ "$USE_LTO" = "yes" ]; then
  COMMON_CFLAGS="$COMMON_CFLAGS $LTO_CFLAGS"
  COMMON_CXXFLAGS="$COMMON_CXXFLAGS $LTO_CFLAGS"
  COMMON_LDFLAGS="$COMMON_LDFLAGS $LTO_CFLAGS"
fi

export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CXXFLAGS"
# Don't export LDFLAGS globally - many autotools builds incorrectly pass it
# to the compiler during compilation, causing warnings. Instead, we pass
# LDFLAGS explicitly to builds that handle it correctly, or use
# COMMON_LDFLAGS_PATHS for builds that just need library search paths.
export LDFLAGS="$COMMON_LDFLAGS_PATHS"

ls "./$MUSL_VERSION/include/linux/mman.h"

sudo chown -R $(whoami) "./$MUSL_VERSION"

# Helper function for consistent CMake configuration
run_cmake() {
  local source_dir="$1"
  shift
  local extra_args=("$@")

  # For clang targeting musl:
  # CLANG_TARGET_FLAGS: compile-time flags (--target, --sysroot, --gcc-toolchain)
  # CLANG_LINK_FLAGS: link-time flags (same + -fuse-ld=lld)
  # (Both are empty for gcc builds)
  
  # LTO flags for cross-language optimization
  local LTO_FLAGS=""
  if [ "$MUSL_USE_LTO" = "yes" ]; then
    LTO_FLAGS="-flto=thin"
  fi

  local cmake_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX"
    -DCMAKE_C_COMPILER="$CMAKE_C_COMPILER"
    -DCMAKE_CXX_COMPILER="$CMAKE_CXX_COMPILER"
    -DCMAKE_AR="$AR"
    -DCMAKE_C_COMPILER_AR="$AR"
    -DCMAKE_CXX_COMPILER_AR="$AR"
    -DCMAKE_RANLIB="$RANLIB"
    -DCMAKE_C_COMPILER_RANLIB="$RANLIB"
    -DCMAKE_CXX_COMPILER_RANLIB="$RANLIB"
    -DCMAKE_C_FLAGS="$CLANG_TARGET_FLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS $LTO_FLAGS -O3"
    -DCMAKE_CXX_FLAGS="$CLANG_TARGET_FLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS $SECURITY_CXXFLAGS $LTO_FLAGS -O3"
    -DCMAKE_EXE_LINKER_FLAGS="$CLANG_LINK_FLAGS -L$SYSROOT_PREFIX/lib $OPT_LDFLAGS $SECURITY_LDFLAGS $LTO_FLAGS"
    -DCMAKE_SHARED_LINKER_FLAGS="$CLANG_LINK_FLAGS -L$SYSROOT_PREFIX/lib $OPT_LDFLAGS $SECURITY_LDFLAGS $LTO_FLAGS"
    -DCMAKE_MODULE_LINKER_FLAGS="$CLANG_LINK_FLAGS -L$SYSROOT_PREFIX/lib $OPT_LDFLAGS $SECURITY_LDFLAGS $LTO_FLAGS"
  )

  if [ "$USE_SCCACHE" = "yes" ]; then
    cmake_args+=(
      -DCMAKE_C_COMPILER_LAUNCHER="$SCCACHE_BIN"
      -DCMAKE_CXX_COMPILER_LAUNCHER="$SCCACHE_BIN"
    )
  fi

  cmake "$source_dir" "${cmake_args[@]}" "${extra_args[@]}"
}

# CMake helper for runtime-library builds. Identical surface to run_cmake
# but routes flags through the unified cflags profile (when enabled). Also
# always re-asserts --target/--sysroot/--gcc-toolchain so the build pins to
# musl even if a sub-build's cmake auto-detects a system clang.
run_cmake_runtime() {
  local source_dir="$1"
  shift
  local extra_args=("$@")

  # When the profile is disabled, behave exactly like run_cmake so existing
  # call sites keep working.
  if [ "$USE_CFLAGS_PROFILE" != "yes" ]; then
    run_cmake "$source_dir" "${extra_args[@]}"
    return $?
  fi

  local cc_flags
  local cxx_flags
  local ld_flags
  cc_flags="$(runtime_cc_flags)"
  cxx_flags="$(runtime_cxx_flags)"
  ld_flags="$(runtime_ld_flags)"

  local cmake_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX"
    -DCMAKE_C_COMPILER="$CMAKE_C_COMPILER"
    -DCMAKE_CXX_COMPILER="$CMAKE_CXX_COMPILER"
    -DCMAKE_AR="$AR"
    -DCMAKE_C_COMPILER_AR="$AR"
    -DCMAKE_CXX_COMPILER_AR="$AR"
    -DCMAKE_RANLIB="$RANLIB"
    -DCMAKE_C_COMPILER_RANLIB="$RANLIB"
    -DCMAKE_CXX_COMPILER_RANLIB="$RANLIB"
    -DCMAKE_C_FLAGS="$cc_flags"
    -DCMAKE_CXX_FLAGS="$cxx_flags"
    -DCMAKE_EXE_LINKER_FLAGS="$ld_flags"
    -DCMAKE_SHARED_LINKER_FLAGS="$ld_flags"
    -DCMAKE_MODULE_LINKER_FLAGS="$ld_flags"
  )

  if [ "$USE_SCCACHE" = "yes" ]; then
    cmake_args+=(
      -DCMAKE_C_COMPILER_LAUNCHER="$SCCACHE_BIN"
      -DCMAKE_CXX_COMPILER_LAUNCHER="$SCCACHE_BIN"
    )
  fi

  cmake "$source_dir" "${cmake_args[@]}" "${extra_args[@]}"
}

## Build musl (bootstrap compiler)
echo "------- Building musl (phase 1)..."
pushd musl

rm -fr mimalloc
make distclean || true
rm -f config.mak

make clean

# Save current environment
SAVED_CC="$CC"
SAVED_CXX="$CXX"
SAVED_CFLAGS="$CFLAGS"
SAVED_CXXFLAGS="$CXXFLAGS"

# Unset to prevent any interference, then pass explicitly to configure
unset CC CXX CFLAGS CXXFLAGS

# Pass CC and CFLAGS directly on command line to ensure -fno-fast-math takes effect
# Use system GCC to avoid any specs issues
./configure \
  CC="gcc" \
  CFLAGS="-fno-fast-math" \
  --prefix="$SYSROOT_PREFIX" \
  --with-malloc=mallocng \
  --enable-optimize=internal,malloc,string

# Musl-specific flags for actual compilation
MUSL_CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3"

make -j${JOBS} \
  CFLAGS_AUTO="$MUSL_CFLAGS" \
  CFLAGS_MEMOPS="$MUSL_CFLAGS" \
  CFLAGS_LDSO="$MUSL_CFLAGS" \
  ADD_CFI=$CFI \
  | tee buildlog.txt

# Debug: Check detected architecture
echo "=== Musl Configuration ==="
grep "^ARCH" config.mak
echo "Expected: ARCH = $(uname -m)"
echo "=========================="

make install

# Restore environment for subsequent builds
export CC="$SAVED_CC"
export CXX="$SAVED_CXX"
export CFLAGS="$SAVED_CFLAGS"
export CXXFLAGS="$SAVED_CXXFLAGS"

popd

# Create architecture-specific symlinks AFTER musl is installed
echo "Creating architecture-specific compiler symlinks..."
pushd "$MUSL_VERSION/bin"
if [ "$ARCH_FLAVOR" = "x86_64" ]; then
  if [ ! -f x86_64-linux-musl-gcc ]; then
    ln -s musl-gcc x86_64-linux-musl-gcc
  fi
elif [ "$ARCH_FLAVOR" = "aarch64" ]; then
  if [ ! -f aarch64-linux-musl-gcc ]; then
    ln -s musl-gcc aarch64-linux-musl-gcc
  fi
fi
popd

if [ "$USE_MUSL_CROSSMAKE" = "yes" ]; then
  ## Build musl-cross-make
  echo "------- Building musl-cross-make..."

  cp -fv config.mak musl-cross-make/config.mak
  pushd musl-cross-make

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS make clean || echo "Nothing to clean."
  fi

  echo "Building 'musl-cross-make'..."

  # Always build GCC with GCC - clang doesn't understand GCC-specific flags
  # like -Wshadow=local and GCC's build system assumes GCC
  # Clear CFLAGS/LDFLAGS to avoid passing clang-specific flags like --gcc-toolchain
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
  make -j${JOBS} \
    CC=gcc \
    CXX=g++ \
    MUSL_ARCH="$ARCH_FLAVOR" \
    OUTPUT="$SYSROOT_PREFIX" \
    TARGET=$MUSL_TARGET \
    TUNE=$C_TARGET_TUNE \
    TARGET_MARCH=$C_TARGET_ARCH \
    HARDEN=$HARDEN \
    CFI=$CFI \
    MPK=$MPK \
    install 2>&1 > buildlog.txt

  popd
fi

echo "Smoketesting compiler..."
MUSL_GCC="$SYSROOT_PREFIX/bin/musl-gcc"
$MUSL_GCC --version

# Set up compiler paths for subsequent builds
if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
  CC_NO_PREFIX="$CC"
  CXX_NO_PREFIX="$CXX"
  BOOTSTRAP_COMPILER_CC="$CC"
  BOOTSTRAP_COMPILER_CXX="$CXX"
else
  # For GCC, check if musl-cross-make produced the expected compilers
  if [ "$USE_MUSL_CROSSMAKE" = "yes" ] && [ -x "$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" ]; then
    CC_NO_PREFIX="$SYSROOT_PREFIX/bin/musl-gcc"
    CXX_NO_PREFIX="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++"
    BOOTSTRAP_COMPILER_CC="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc"
    BOOTSTRAP_COMPILER_CXX="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++"
  else
    # Fall back to musl-gcc wrapper with system g++ for C++
    CC_NO_PREFIX="$SYSROOT_PREFIX/bin/musl-gcc"
    CXX_NO_PREFIX="$CXX"
    BOOTSTRAP_COMPILER_CC="$SYSROOT_PREFIX/bin/musl-gcc"
    BOOTSTRAP_COMPILER_CXX="$CXX"
    echo "WARNING: Using musl-gcc wrapper with system C++ compiler for bootstrap"
  fi
fi

# Update CFLAGS with sysroot paths (no self-append)
# Do NOT include /usr/include paths - those are glibc headers which conflict with musl
# Note: CLANG_TARGET_FLAGS is NOT included in global exports because some builds
# (like musl phase 2) use gcc which doesn't understand --gcc-toolchain.
# CLANG_TARGET_FLAGS is used explicitly in run_cmake() for cmake builds.
export CFLAGS="-I$SYSROOT_PREFIX/include -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3"
export CXXFLAGS="$CFLAGS $SECURITY_CXXFLAGS"
# Only export library paths - security linker flags cause warnings when
# autotools incorrectly passes LDFLAGS to compiler during compilation
export LDFLAGS="-L$SYSROOT_PREFIX/lib -L$SYSROOT_PREFIX/lib64"

# Set CC/CXX with optional sccache wrapper
if [ "$USE_SCCACHE" = "yes" ]; then
  export CC="$SCCACHE_BIN $CC_NO_PREFIX"
  export CXX="$SCCACHE_BIN $CXX_NO_PREFIX"
else
  export CC="$CC_NO_PREFIX"
  export CXX="$CXX_NO_PREFIX"
fi

## Build mimalloc
echo "------- Building mimalloc..."
pushd mimalloc
rm -fr out/release
mkdir -p out/release
pushd out/release

# When integrating mimalloc into musl libc, we must disable MI_OVERRIDE
# to prevent symbol conflicts (strdup, strndup, valloc, etc.)
# Our glue code will provide the redirections instead.
if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
  MI_OVERRIDE_SETTING="OFF"
  echo "Building mimalloc for musl integration (MI_OVERRIDE=OFF)"
else
  MI_OVERRIDE_SETTING="ON"
  echo "Building mimalloc standalone (MI_OVERRIDE=ON)"
fi

run_cmake ../.. \
  -DMI_SECURE=$SECURE \
  -DMI_GUARDED=$GUARDED \
  -DMI_OPT_ARCH=ON \
  -DMI_SEE_ASM=ON \
  -DMI_LIBC_MUSL=ON \
  -DMI_BUILD_SHARED=OFF \
  -DMI_BUILD_STATIC=ON \
  -DMI_BUILD_OBJECT=ON \
  -DMI_BUILD_TESTS=OFF \
  -DMI_OVERRIDE=$MI_OVERRIDE_SETTING \
  -DMI_EXTRA_CPPDEFS="MI_DEFAULT_ARENA_RESERVE=33554432;MI_DEFAULT_ALLOW_LARGE_OS_PAGES=0" \
  -DMI_SKIP_COLLECT_ON_EXIT=1

make -j${JOBS} | tee buildlog.txt
make install
popd
popd
echo "Mimalloc done."

# Build mimalloc-musl glue code if integration is enabled
if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
  echo "------- Building mimalloc-musl glue code..."
  
  GLUE_SRC="$ROOT_DIR/src/mimalloc-musl-glue.c"
  GLUE_OBJ="$ROOT_DIR/mimalloc/out/release/mimalloc-musl-glue.o"
  MIMALLOC_INCLUDE="$ROOT_DIR/mimalloc/include"
  
  if [ ! -f "$GLUE_SRC" ]; then
    echo "ERROR: mimalloc-musl-glue.c not found at $GLUE_SRC"
    echo "This file is required for MUSL_USE_MIMALLOC=yes"
    exit 1
  fi
  
  # LTO flags for cross-language optimization (must match musl build)
  GLUE_LTO_FLAGS=""
  if [ "$MUSL_USE_LTO" = "yes" ]; then
    GLUE_LTO_FLAGS="-flto=thin"
  fi
  
  # Compile glue code with same flags as mimalloc, plus musl and mimalloc headers
  # CLANG_TARGET_FLAGS contains sysroot/gcc-toolchain for clang, empty for gcc
  $CC_NO_PREFIX -c -O3 -fPIC \
    $CLANG_TARGET_FLAGS \
    $GLUE_LTO_FLAGS \
    -fno-fast-math -U_FORTIFY_SOURCE \
    -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE \
    -ffunction-sections -fdata-sections \
    -I"$MIMALLOC_INCLUDE" \
    -I"$SYSROOT_PREFIX/include" \
    "$GLUE_SRC" \
    -o "$GLUE_OBJ"
  
  if [ ! -f "$GLUE_OBJ" ]; then
    echo "ERROR: Failed to compile mimalloc-musl-glue.c"
    exit 1
  fi
  
  echo "Glue code compiled: $GLUE_OBJ"
fi

### Build LLVM
if [ "$BUILD_LLVM" != "yes" ]; then
  echo "Skipping LLVM build."
else
  echo "------- Building LLVM..."
  pushd llvm

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    echo "Cleaning previous LLVM build ..."
    rm -fr build
    git checkout .
    git clean -xdf
  fi

  mkdir -p build
  popd
  pushd llvm/build

  # LLVM is built as a HOST tool (runs on the build machine) against glibc.
  # It gets installed to the sysroot prefix but is NOT cross-compiled.
  # Use the SYSTEM compiler (not musl-gcc wrapper) to build against glibc.
  #
  # The resulting clang/lld will be native glibc binaries that can target musl
  # via --target and --sysroot flags when invoked.
  
  # Save current environment
  SAVED_CC="$CC"
  SAVED_CXX="$CXX"
  SAVED_CFLAGS="$CFLAGS"
  SAVED_CXXFLAGS="$CXXFLAGS"
  SAVED_LDFLAGS="$LDFLAGS"
  
  # Clear environment to prevent musl sysroot contamination
  # CMake may append environment CFLAGS/CXXFLAGS to CMAKE_*_FLAGS
  unset CC CXX CFLAGS CXXFLAGS LDFLAGS
  
  # Determine system compiler - prefer the one matching PREFER_COMPILER_FAMILY
  if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
    LLVM_HOST_CC=$(which clang)
    LLVM_HOST_CXX=$(which clang++)
    LLVM_HOST_AR=$(which llvm-ar 2>/dev/null || which ar)
    LLVM_HOST_RANLIB=$(which llvm-ranlib 2>/dev/null || which ranlib)
  else
    LLVM_HOST_CC=$(which gcc)
    LLVM_HOST_CXX=$(which g++)
    LLVM_HOST_AR=$(which gcc-ar 2>/dev/null || which ar)
    LLVM_HOST_RANLIB=$(which gcc-ranlib 2>/dev/null || which ranlib)
  fi
  
  echo "Building LLVM with host compiler: $LLVM_HOST_CC / $LLVM_HOST_CXX"
  
  # Explicitly use host system headers/libraries, not musl sysroot
  # For clang, we need to prevent it from auto-detecting the GCC in the musl sysroot
  # and instead use the system GCC's libstdc++
  LLVM_HOST_CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3"
  LLVM_HOST_CXXFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3"
  
  # Note: We don't add --gcc-install-dir here because:
  # 1. The environment is clean (no musl sysroot in CC/CXX/CFLAGS)
  # 2. Clang will use its default search paths to find system GCC's libstdc++
  # 3. --gcc-install-dir requires the actual gcc lib path (e.g., /usr/lib/gcc/x86_64-linux-gnu/13)
  #    not just the prefix, and this varies by distro
  
  # Check for binutils plugin-api.h to build LLVMgold.so
  # This allows GNU ld to perform LTO with LLVM bitcode
  BINUTILS_INCDIR=""
  for dir in /usr/include /usr/local/include; do
    if [ -f "$dir/plugin-api.h" ]; then
      BINUTILS_INCDIR="$dir"
      echo "Found binutils plugin API at $BINUTILS_INCDIR - will build LLVMgold.so"
      break
    fi
  done
  if [ -z "$BINUTILS_INCDIR" ]; then
    echo "WARNING: binutils plugin-api.h not found - LLVMgold.so will not be built"
    echo "         Install binutils-dev/binutils-devel to enable GNU ld LTO support"
  fi
  
  LLVM_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX"
    -DCMAKE_C_COMPILER="$LLVM_HOST_CC"
    -DCMAKE_CXX_COMPILER="$LLVM_HOST_CXX"
    -DCMAKE_AR="$LLVM_HOST_AR"
    -DCMAKE_RANLIB="$LLVM_HOST_RANLIB"
    -DCMAKE_C_FLAGS="$LLVM_HOST_CFLAGS"
    -DCMAKE_CXX_FLAGS="$LLVM_HOST_CXXFLAGS"
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  )
  
  # Add LLVMgold.so build if binutils headers available
  if [ -n "$BINUTILS_INCDIR" ]; then
    LLVM_CMAKE_ARGS+=(-DLLVM_BINUTILS_INCDIR="$BINUTILS_INCDIR")
  fi

  if [ "$USE_SCCACHE" = "yes" ]; then
    LLVM_CMAKE_ARGS+=(
      -DCMAKE_C_COMPILER_LAUNCHER="$SCCACHE_BIN"
      -DCMAKE_CXX_COMPILER_LAUNCHER="$SCCACHE_BIN"
    )
  fi

  # Per-target runtimes: compiler-rt is cross-built with the just-built clang
  # against the musl sysroot we already installed via musl-cross-make. The
  # `RUNTIMES_<target>_` prefix scopes each cmake var into the runtimes
  # sub-build only — it doesn't leak into the host LLVM compile (which still
  # builds against glibc).
  cmake ../llvm "${LLVM_CMAKE_ARGS[@]}" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
    -DLLVM_ENABLE_RUNTIMES="$LLVM_RUNTIMES" \
    -DLLVM_RUNTIME_TARGETS="$MUSL_TARGET" \
    -DRUNTIMES_${MUSL_TARGET}_CMAKE_SYSROOT="$SYSROOT_PREFIX/$MUSL_TARGET" \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_BUILTINS=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_PROFILE=ON \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_SANITIZERS=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_MEMPROF=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_XRAY=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_ORC=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DRUNTIMES_${MUSL_TARGET}_COMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_BUILD_32_BITS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_BUILD_BENCHMARKS=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$MUSL_TARGET" \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DBOLT_ENABLE_RUNTIME=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--no-as-needed" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--no-as-needed"

  make -j${JOBS}
  make install
  echo "LLVM build complete."
  
  # Restore environment
  export CC="$SAVED_CC"
  export CXX="$SAVED_CXX"
  export CFLAGS="$SAVED_CFLAGS"
  export CXXFLAGS="$SAVED_CXXFLAGS"
  export LDFLAGS="$SAVED_LDFLAGS"
  
  sleep 3
  popd
fi

## Build Propeller before swapping compilers.
if [ "$BUILD_PROPELLER" != "yes" ]; then
  echo "Skipping Propeller build."
else
  echo "------- Building Propeller..."
  # Propeller is a HOST tool, same as LLVM. Build it against the host
  # compiler/glibc, not the musl sysroot we set up earlier — otherwise the
  # downloaded protobuf's atomics check fails, which trips a real bug in
  # protobuf 33.4's protobuf-configure-target.cmake.
  PROPELLER_LLVM_CMAKE_DIR="$(pwd)/llvm/build/lib/cmake/llvm"
  PROPELLER_PATCH_DIR="$(pwd)/src/patches/llvm-propeller"
  if [ ! -f "$PROPELLER_LLVM_CMAKE_DIR/LLVMConfig.cmake" ]; then
    echo "ERROR: $PROPELLER_LLVM_CMAKE_DIR/LLVMConfig.cmake not found."
    echo "       Build LLVM first (BUILD_LLVM=yes) before building Propeller."
    exit 1
  fi

  # Save the musl-targeted environment so we can restore it after.
  PROP_SAVED_CC="$CC"
  PROP_SAVED_CXX="$CXX"
  PROP_SAVED_CFLAGS="$CFLAGS"
  PROP_SAVED_CXXFLAGS="$CXXFLAGS"
  PROP_SAVED_LDFLAGS="$LDFLAGS"
  # Clear environment to prevent musl sysroot contamination of cmake config tests.
  unset CC CXX CFLAGS CXXFLAGS LDFLAGS

  # Use the exact compiler LLVM was built with — propeller links against
  # LLVM's static libs, so ABI / libstdc++ versions must match. Reading from
  # LLVM's CMakeCache.txt also avoids picking up our own musl-targeted clang
  # via PATH (e.g. via $ROOT_DIR/latest/bin) which would build against musl
  # and break protobuf's atomics check.
  PROP_HOST_CC=$(awk -F= '/^CMAKE_C_COMPILER:/{print $2}' "$(pwd)/llvm/build/CMakeCache.txt")
  PROP_HOST_CXX=$(awk -F= '/^CMAKE_CXX_COMPILER:/{print $2}' "$(pwd)/llvm/build/CMakeCache.txt")
  if [ -z "$PROP_HOST_CC" ] || [ -z "$PROP_HOST_CXX" ]; then
    echo "ERROR: could not read CMAKE_C_COMPILER/CMAKE_CXX_COMPILER from llvm/build/CMakeCache.txt"
    exit 1
  fi
  PROP_HOST_CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3"
  PROP_HOST_CXXFLAGS="$PROP_HOST_CFLAGS"
  echo "Building Propeller with host compiler: $PROP_HOST_CC / $PROP_HOST_CXX"

  pushd llvm-propeller
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    echo "Cleaning previous proppeller build ..."
    rm -fr build
    git checkout .
    git clean -xdf
  fi
  # Re-apply our local propeller patches (find_package(LLVM CONFIG) wiring +
  # MCContext API fix for LLVM 22) idempotently. The clean step above resets
  # the submodule, so patches must be re-applied each run.
  if [ -d "$PROPELLER_PATCH_DIR" ]; then
    for patch in "$PROPELLER_PATCH_DIR"/*.patch; do
      [ -e "$patch" ] || continue
      if git apply --check "$patch" 2>/dev/null; then
        echo "Applying $(basename "$patch")"
        git apply "$patch"
      elif git apply --reverse --check "$patch" 2>/dev/null; then
        echo "Already applied: $(basename "$patch")"
      else
        echo "ERROR: cannot apply patch $patch (and it's not already applied)"
        exit 1
      fi
    done
  fi
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$PROP_HOST_CC" \
    -DCMAKE_CXX_COMPILER="$PROP_HOST_CXX" \
    -DCMAKE_C_FLAGS="$PROP_HOST_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$PROP_HOST_CXXFLAGS" \
    -DLLVM_DIR="$PROPELLER_LLVM_CMAKE_DIR"
  pushd build;
  make -j`nproc`
  make install
  popd
  popd

  # Restore musl-targeted environment for the rest of the script.
  export CC="$PROP_SAVED_CC"
  export CXX="$PROP_SAVED_CXX"
  export CFLAGS="$PROP_SAVED_CFLAGS"
  export CXXFLAGS="$PROP_SAVED_CXXFLAGS"
  export LDFLAGS="$PROP_SAVED_LDFLAGS"
fi

## Update compilers after LLVM build if using clang
if [ "$PREFER_COMPILER_FAMILY" = "clang" ]; then
  LTO_CFLAGS="$CLANG_LTOFLAGS"
  if [ "$BUILD_LLVM" = "yes" ]; then
    CMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/clang"
    CMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/clang++"
    CC_NO_PREFIX="$SYSROOT_PREFIX/bin/clang"
    CXX_NO_PREFIX="$SYSROOT_PREFIX/bin/clang++"
    export LD="$SYSROOT_PREFIX/bin/ld.lld"
    export AR="$SYSROOT_PREFIX/bin/llvm-ar"
    export NM="$SYSROOT_PREFIX/bin/llvm-nm"
    export RANLIB="$SYSROOT_PREFIX/bin/llvm-ranlib"
  else
    CMAKE_C_COMPILER="$CC"
    CMAKE_CXX_COMPILER="$CXX"
    CC_NO_PREFIX="$CC"
    CXX_NO_PREFIX="$CXX"
  fi
else
  LTO_CFLAGS="$GCC_LTOFLAGS"
  # Check if musl-cross-make produced the expected compilers
  if [ -x "$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" ]; then
    CMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc"
    CMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++"
    CC_NO_PREFIX="$SYSROOT_PREFIX/bin/musl-gcc"
    CXX_NO_PREFIX="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++"
    export LD="$SYSROOT_PREFIX/bin/ld"
    # Use sysroot gcc-ar if available, otherwise fall back to system
    if [ -x "$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc-ar" ]; then
      export AR="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc-ar"
      export NM="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc-nm"
      export RANLIB="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc-ranlib"
    else
      export AR=$(which gcc-ar 2>/dev/null || which ar)
      export NM=$(which gcc-nm 2>/dev/null || which nm)
      export RANLIB=$(which gcc-ranlib 2>/dev/null || which ranlib)
    fi
  else
    # Fall back to musl-gcc wrapper with system tools
    CMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/musl-gcc"
    CMAKE_CXX_COMPILER="$CXX"
    CC_NO_PREFIX="$SYSROOT_PREFIX/bin/musl-gcc"
    CXX_NO_PREFIX="$CXX"
    # Keep existing AR/RANLIB from bootstrap
  fi
fi

echo "Post-LLVM compiler: $CMAKE_C_COMPILER"
echo "Post-LLVM archiver: $AR"

# Update CC/CXX with new compiler paths
if [ "$USE_SCCACHE" = "yes" ]; then
  export CC="$SCCACHE_BIN $CC_NO_PREFIX"
  export CXX="$SCCACHE_BIN $CXX_NO_PREFIX"
else
  export CC="$CC_NO_PREFIX"
  export CXX="$CXX_NO_PREFIX"
fi

## Build musl (phase 2 + mimalloc)
#
# NOTE: For MUSL_USE_MIMALLOC=yes to work, musl must be patched to:
# 1. Recognize USE_MIMALLOC=yes make variable
# 2. Exclude src/malloc/*.c (native allocator) when USE_MIMALLOC=yes
# 3. Exclude src/legacy/valloc.c when USE_MIMALLOC=yes  
# 4. Exclude src/string/strdup.c when USE_MIMALLOC=yes
# 5. Exclude src/string/strndup.c when USE_MIMALLOC=yes
# 6. Link objects from mimalloc/objs/*.o into libc.a
#
# The patched musl Makefile should have something like:
#   ifeq ($(USE_MIMALLOC),yes)
#   MALLOC_SRCS =
#   MIMALLOC_OBJS = $(wildcard mimalloc/objs/*.o)
#   else
#   MALLOC_SRCS = $(wildcard src/malloc/*.c)
#   MIMALLOC_OBJS =
#   endif
#
if [ "$BUILD_STAGE2" = "yes" ]; then
  echo "------- Building musl (phase 2)..."
  pushd musl

  mkdir -p mimalloc/objs
  rm -fv buildlog.txt mimalloc/objs/*
  rm -f config.mak
  make distclean || true

  if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
    echo "Integrating mimalloc into musl libc..."
    
    # Copy mimalloc object file
    MIMALLOC_OBJ="../mimalloc/out/release/mimalloc.o"
    if [ ! -f "$MIMALLOC_OBJ" ]; then
      echo "ERROR: mimalloc.o not found at $MIMALLOC_OBJ"
      echo "Build mimalloc first with MI_BUILD_OBJECT=ON"
      exit 1
    fi
    cp -fv "$MIMALLOC_OBJ" ./mimalloc/objs/
    
    # Copy glue code object file
    GLUE_OBJ="../mimalloc/out/release/mimalloc-musl-glue.o"
    if [ ! -f "$GLUE_OBJ" ]; then
      echo "ERROR: mimalloc-musl-glue.o not found at $GLUE_OBJ"
      echo "The glue code should have been compiled after mimalloc"
      exit 1
    fi
    cp -fv "$GLUE_OBJ" ./mimalloc/objs/
    
    echo "Mimalloc objects staged for musl integration:"
    ls -la ./mimalloc/objs/
  else
    echo "Not using mimalloc in musl build (using native mallocng allocator)."
  fi

  make clean

  # Save current environment
  SAVED_CC="$CC"
  SAVED_CXX="$CXX"
  SAVED_CFLAGS="$CFLAGS"
  SAVED_CXXFLAGS="$CXXFLAGS"

  # Unset to prevent any interference, then pass explicitly to configure
  unset CC CXX CFLAGS CXXFLAGS

  # Determine compiler and flags for musl build
  # When MUSL_USE_LTO=yes, use clang with -flto=thin for cross-language LTO with Rust
  # Otherwise, use GCC for maximum compatibility
  #
  # IMPORTANT (LTO target-triple correctness): with -flto=thin, every musl
  # object is LLVM bitcode (.lo) and the bitcode embeds the target triple
  # *baked from the compile command line*. If we invoke a bare `clang`, it
  # picks up whichever clang resolves first on $PATH, and a system clang
  # defaults to x86_64-pc-linux-gnu (glibc). When a downstream Rust binary
  # then LTO-links libc.a, lld warns "Linking two modules of different
  # target triples: ... is 'x86_64-pc-linux-gnu' whereas ... is
  # 'x86_64-unknown-linux-musl'" for every libc.a member it pulls in.
  #
  # Two defenses below: (1) point at the just-built clang by absolute path
  # so PATH order doesn't matter, (2) pin the target/sysroot/gcc-toolchain
  # explicitly so the bitcode triple is always x86_64-(unknown-)linux-musl
  # regardless of which clang ends up running.
  MUSL_TARGET_FLAGS=""
  if [ "$MUSL_USE_LTO" = "yes" ]; then
    if [ -x "$SYSROOT_PREFIX/bin/clang" ]; then
      MUSL_CC="$SYSROOT_PREFIX/bin/clang"
    else
      MUSL_CC="clang"
    fi
    MUSL_AR="llvm-ar"
    MUSL_RANLIB="llvm-ranlib"
    MUSL_TARGET_FLAGS="--target=$MUSL_TARGET --sysroot=$SYSROOT_PREFIX --gcc-toolchain=$SYSROOT_PREFIX"
    MUSL_LTO_FLAGS="-flto=thin $MUSL_TARGET_FLAGS"
    # For linking libc.so with LTO, we need special handling:
    # 1. The ldso bootstrap has asm→C calls (__dls2, __dls3) that LTO doesn't see
    # 2. We use --undefined to force the linker to keep these symbols
    # 3. -fno-lto tells lld to not run LTO optimization on the final link
    # The LTO bitcode in libc.a is what matters for static linking with Rust
    MUSL_LDFLAGS="$MUSL_TARGET_FLAGS -fuse-ld=lld -fno-lto -Wl,--undefined=__dls2 -Wl,--undefined=__dls3"
    echo "Building musl with LTO (clang + ThinLTO + lld for cross-language optimization)"
    echo "  compiler: $MUSL_CC"
    echo "  target:   $MUSL_TARGET (pinned via --target/--sysroot)"
    echo "Note: libc.so linked without LTO to preserve ldso bootstrap; libc.a has LTO bitcode"
  else
    MUSL_CC="gcc"
    MUSL_AR="ar"
    MUSL_RANLIB="ranlib"
    MUSL_LTO_FLAGS=""
    MUSL_LDFLAGS=""
  fi

  # Configure musl
  # When USE_MIMALLOC=yes, we don't specify --with-malloc since the patched
  # musl will skip building its native allocator and use our mimalloc objects.
  # When USE_MIMALLOC=no, we explicitly select mallocng for best performance.
  if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
    ./configure \
      CC="$MUSL_CC" \
      AR="$MUSL_AR" \
      RANLIB="$MUSL_RANLIB" \
      CFLAGS="-fno-fast-math $MUSL_TARGET_FLAGS $MUSL_LTO_FLAGS" \
      LDFLAGS="$MUSL_LDFLAGS" \
      --prefix="$SYSROOT_PREFIX" \
      --enable-optimize=internal,malloc,string
  else
    ./configure \
      CC="$MUSL_CC" \
      AR="$MUSL_AR" \
      RANLIB="$MUSL_RANLIB" \
      CFLAGS="-fno-fast-math $MUSL_TARGET_FLAGS $MUSL_LTO_FLAGS" \
      LDFLAGS="$MUSL_LDFLAGS" \
      --prefix="$SYSROOT_PREFIX" \
      --with-malloc=mallocng \
      --enable-optimize=internal,malloc,string
  fi

  # Musl-specific flags for actual compilation. MUSL_LTO_FLAGS already
  # carries MUSL_TARGET_FLAGS (--target/--sysroot/--gcc-toolchain) when LTO
  # is on; that's what gives every .lo bitcode module the correct target
  # triple. CFLAGS_LDSO is built without MUSL_LTO_FLAGS (it overrides with
  # -fno-lto), so we add MUSL_TARGET_FLAGS there explicitly to keep the
  # ldso .o files driver-consistent — strictly, dropping the LTO portion
  # for ldso doesn't require this, but it costs nothing and prevents a
  # PATH-resolved system clang from compiling ldso against glibc headers.
  MUSL_CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 $MUSL_LTO_FLAGS"

  # LDSO (dynamic linker) flags - explicitly NO LTO with -fno-lto!
  # The ldso bootstrap code (dlstart.c) has assembly that calls hidden C functions
  # (__dls2, __dls3). LTO doesn't see these asm references and eliminates the functions.
  # CFLAGS_LDSO is ADDED to CFLAGS_ALL in musl's Makefile, so -fno-lto overrides -flto=thin.
  MUSL_CFLAGS_LDSO="$MUSL_TARGET_FLAGS -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 -fno-lto"

  make -j${JOBS} \
    CC="$MUSL_CC" \
    AR="$MUSL_AR" \
    RANLIB="$MUSL_RANLIB" \
    CFLAGS_AUTO="$MUSL_CFLAGS" \
    CFLAGS_MEMOPS="$MUSL_CFLAGS" \
    CFLAGS_LDSO="$MUSL_CFLAGS_LDSO" \
    LDFLAGS="$MUSL_LDFLAGS" \
    USE_MIMALLOC=$MUSL_USE_MIMALLOC \
    ADD_CFI=$CFI \
    | tee buildlog.txt

  make install

  # Restore environment for subsequent builds
  export CC="$SAVED_CC"
  export CXX="$SAVED_CXX"
  export CFLAGS="$SAVED_CFLAGS"
  export CXXFLAGS="$SAVED_CXXFLAGS"

  popd
fi

## Build zlib
if [ "$BUILD_ZLIB" != "yes" ]; then
  echo "Skipping zlib build."
else
  echo "------- Building zlib..."
  pushd zlib
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean."
  fi
  if [ "$ARCH_FLAVOR" = "x86_64" ]; then
    ZLIB_FLAGS="--64"
  else
    ZLIB_FLAGS=""
  fi

  CC="$CC_NO_PREFIX" \
  CFLAGS="$(runtime_cc_flags)" \
  LDFLAGS="$(runtime_ld_flags)" \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --const \
    --static \
    $ZLIB_FLAGS
  make -j${JOBS} CC="$CC_NO_PREFIX" AR="$AR"
  make install
  popd
fi

## Build zlib-ng
if [ "$BUILD_ZLIB_NG" != "yes" ]; then
  echo "Skipping zlib-ng build."
else
  echo "------- Building zlib-ng..."
  pushd zlib-ng
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean."
  fi

  CC="$CC_NO_PREFIX" \
  CFLAGS="$(runtime_cc_flags)" \
  LDFLAGS="$(runtime_ld_flags)" \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --static \
    --zlib-compat
  make -j${JOBS} CC="$CC_NO_PREFIX" AR="$AR"
  make install
  popd
fi

### Build zstd
if [ "$BUILD_ZSTD" != "yes" ]; then
  echo "Skipping zstd build."
else
  echo "------- Building zstd..."
  pushd zstd
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake
    make clean || echo "Nothing to clean."
  fi

  run_cmake_runtime . -B build-cmake \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_MULTITHREAD_SUPPORT=ON

  cmake --build build-cmake -j${JOBS}
  cmake --install build-cmake

  popd
fi

## Build brotli
if [ "$BUILD_BROTLI" != "yes" ]; then
  echo "Skipping brotli build."
else
  echo "------- Building brotli..."
  pushd brotli
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake
    make clean || echo "Nothing to clean."
  fi

  run_cmake_runtime . -B build-cmake \
    -DBUILD_SHARED_LIBS=OFF

  cmake --build build-cmake -j${JOBS}
  cmake --install build-cmake

  popd
fi

## Build Snappy
if [ "$BUILD_SNAPPY" != "yes" ]; then
  echo "Skipping snappy build."
else
  echo "------- Building snappy..."
  pushd snappy
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake
    make clean || echo "Nothing to clean."
  fi
  mkdir -p build-cmake
  pushd build-cmake

  run_cmake_runtime .. \
    -DSNAPPY_BUILD_TESTS=OFF \
    -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DBUILD_SHARED_LIBS=OFF

  make -j${JOBS}
  make install
  popd
  popd
fi

### Build lz4
if [ "$BUILD_LZ4" != "yes" ]; then
  echo "Skipping lz4 build."
else
  echo "------- Building lz4..."
  pushd lz4
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake
    make clean || echo "Nothing to clean."
  fi

  make \
    PREFIX="$SYSROOT_PREFIX" \
    CC="$CC_NO_PREFIX" \
    AR="$AR" \
    CFLAGS="$(runtime_cc_flags)" \
    LDFLAGS="$(runtime_ld_flags)" \
    -j${JOBS}
  make PREFIX="$SYSROOT_PREFIX" install
  popd
fi

### Build openssl
if [ "$BUILD_OPENSSL" != "yes" ]; then
  echo "Skipping openssl build."
else
  echo "------- Building openssl..."
  pushd openssl
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step"
  fi
  rm -fv buildlog.txt

  if [ "$ARCH_FLAVOR" = "x86_64" ]; then
    OPENSSL_TARGET="linux-x86_64"
  else
    OPENSSL_TARGET="linux-aarch64"
  fi

  ./Configure \
      "$OPENSSL_TARGET" \
      no-shared \
      no-tests \
      no-external-tests \
      no-comp \
      no-afalgeng \
      enable-ec_nistp_64_gcc_128 \
      enable-tls1_3 \
      enable-asm \
      threads \
      -static \
      --prefix="$SYSROOT_PREFIX" \
      --openssldir="$SYSROOT_PREFIX/ssl" \
      CC="$CC_NO_PREFIX" \
      CXX="$CXX_NO_PREFIX" \
      CFLAGS="$(runtime_cc_flags) -fPIE -fPIC" \
      LDFLAGS="$(runtime_ld_flags)"

  make -j$JOBS depend
  make -j$JOBS | tee buildlog.txt
  make install_sw install_ssldirs
  popd
fi

### Build aws-lc
if [ "$BUILD_AWS_LC" != "yes" ]; then
  echo "Skipping aws-lc build."
else
  echo "------- Building aws-lc..."
  pushd aws-lc
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake-static build-cmake-shared
  fi

  # Pass 1: static libraries (libcrypto.a, libssl.a). PIC is enabled so
  # the .a archives can also be linked into downstream shared objects.
  run_cmake_runtime . -B build-cmake-static \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_LIBSSL=ON \
    -DBUILD_TOOL=OFF \
    -DBUILD_TESTING=OFF \
    -DDISABLE_GO=ON \
    -DDISABLE_PERL=ON

  cmake --build build-cmake-static -j${JOBS}
  cmake --install build-cmake-static

  # Pass 2: shared libraries (libcrypto.so, libssl.so), built with the
  # same embedded clang/musl toolchain so they live alongside the .a files.
  run_cmake_runtime . -B build-cmake-shared \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_LIBSSL=ON \
    -DBUILD_TOOL=OFF \
    -DBUILD_TESTING=OFF \
    -DDISABLE_GO=ON \
    -DDISABLE_PERL=ON

  cmake --build build-cmake-shared -j${JOBS}
  cmake --install build-cmake-shared

  popd
fi

### Build sqlite
if [ "$BUILD_SQLITE" != "yes" ]; then
  echo "Skipping sqlite build."
else
  echo "------- Building sqlite..."
  pushd sqlite
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step"
  fi
  rm -fv buildlog.txt

  CC="$CC_NO_PREFIX" \
  CFLAGS="$(runtime_cc_flags)" \
  LDFLAGS="$(runtime_ld_flags)" \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
    --with-tempstore=yes \
    --disable-tcl \
    --disable-shared

  make -j$JOBS | tee buildlog.txt
  make install
  popd
fi

### Build sqlcipher
if [ "$BUILD_SQLCIPHER" != "yes" ]; then
  echo "Skipping sqlcipher build."
else
  echo "------- Building sqlcipher..."
  pushd sqlcipher
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step"
  fi
  rm -fv buildlog.txt

  CC="$CC_NO_PREFIX" \
  CFLAGS="$(runtime_cc_flags) -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown" \
  LDFLAGS="$(runtime_ld_flags) -lcrypto" \
  ./configure \
    --prefix="$SYSROOT_PREFIX/sqlcipher" \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
    --with-tempstore=yes \
    --disable-tcl \
    --disable-shared

  make -j$JOBS | tee buildlog.txt
  make install
  popd
fi

### Build capnp
if [ "$BUILD_CAPNP" != "yes" ]; then
  echo "Skipping capnp build."
else
  echo "------- Building capnp..."

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    make clean || echo "Nothing to clean."
  fi

  cd capnp/c++
  autoreconf -i
  CC="$CC_NO_PREFIX" \
  CXX="$CXX_NO_PREFIX" \
  CFLAGS="$(runtime_cc_flags)" \
  CXXFLAGS="$(runtime_cxx_flags)" \
  LDFLAGS="$(runtime_ld_flags)" \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --with-zlib \
    --with-openssl \
    --with-sysroot="$SYSROOT_PREFIX"
  make -j${JOBS} check
  make install
  cd -
fi

### Build hiredis
if [ "$BUILD_HIREDIS" != "yes" ]; then
  echo "Skipping hiredis build."
else
  pushd hiredis
  echo "------- Building hiredis..."
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean."
  fi
  make \
    -j${JOBS} \
    USE_SSL=1 \
    CC="$CC_NO_PREFIX" \
    AR="$AR" \
    CFLAGS="$(runtime_cc_flags)" \
    LDFLAGS="$(runtime_ld_flags)" \
    PREFIX="$SYSROOT_PREFIX" \
    OPTIMIZATION=-O3 \
    static pkgconfig install \
    | tee buildlog.txt
  popd
fi

### CRC32C
if [ "$BUILD_CRC32C" != "yes" ]; then
  echo "Skipping crc32c build."
else
  git submodule update --init --depth=1 --recursive crc32c
  pushd crc32c
  echo "------- Building crc32c..."
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean."
  fi

  mkdir -p build
  pushd build

  run_cmake_runtime .. \
    -DBUILD_SHARED_LIBS=0 \
    -DCRC32C_BUILD_TESTS=0 \
    -DCRC32C_BUILD_BENCHMARKS=0

  make -j${JOBS}
  make install
  popd
  popd
fi

### Build leveldb
if [ "$BUILD_LEVELDB" != "yes" ]; then
  echo "Skipping leveldb build."
else
  pushd leveldb
  echo "------- Building leveldb..."
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean."
  fi

  mkdir -p build
  pushd build

  run_cmake_runtime .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DLEVELDB_BUILD_TESTS=OFF \
    -DLEVELDB_BUILD_BENCHMARKS=OFF

  make -j${JOBS}
  make install
  popd
  popd
fi

### ======= Done.

set +x -e
sleep 1

echo "Verifying..."
file "$SYSROOT_PREFIX/bin/musl-gcc" || exit 2
file "$SYSROOT_PREFIX/lib/libc.a" || exit 2
if [ "$BUILD_ZLIB" = "yes" ]; then
  file "$SYSROOT_PREFIX/lib/libz.a" || exit 3
fi

if [ "$ARCH_FLAVOR" = "x86_64" ]; then
  OPENSSL_LIB_DIR="lib64"
else
  OPENSSL_LIB_DIR="lib"
fi

if [ "$BUILD_OPENSSL" = "yes" ]; then
  file "$SYSROOT_PREFIX/$OPENSSL_LIB_DIR/libssl.a" || exit 4
fi

echo "Verification complete."

echo "Build complete."
echo "-----------------------------------------------"
echo "Musl Sysroot (${MUSL_VERSION}+p3):"
echo "  Location: $SYSROOT_PREFIX"
echo "  Compiler: $CC_NO_PREFIX"
echo "  Arch:     $C_TARGET_ARCH"
echo "  Tune:     $C_TARGET_TUNE"
echo ""
echo "Compiler flags:"
echo "  CFLAGS:   -I$SYSROOT_PREFIX/include"
echo "  LDFLAGS:  -L$SYSROOT_PREFIX/lib -static"
echo "  CC:       $CC_NO_PREFIX"
echo "  CXX:      $CXX_NO_PREFIX"
echo ""
echo "Components:"
echo "  mimalloc:   3.1.5"
echo "  libc:       1.2.5+p3 $(file "$SYSROOT_PREFIX/lib/libc.a")"
if [ "$BUILD_LLVM" = "yes" ]; then
  echo "  llvm:       21.1.2 $(file "$SYSROOT_PREFIX/bin/clang" 2>/dev/null || echo 'not found')"
fi
if [ "$BUILD_PROPELLER" = "yes" ]; then
  echo "  propeller:  trunk"
fi
if [ "$BUILD_ZLIB" = "yes" ]; then
  echo "  zlib:       1252e25 (cloudflare@gcc.amd64) $(file "$SYSROOT_PREFIX/lib/libz.a")"
fi
if [ "$BUILD_ZLIB_NG" = "yes" ]; then
  echo "  zlib-ng:    2.3.1 $(file "$SYSROOT_PREFIX/lib/libz-ng.a")"
fi
if [ "$BUILD_BROTLI" = "yes" ]; then
  echo "  brotli:     1.2.0 $(file "$SYSROOT_PREFIX/lib/libbrotlidec.a")"
fi
if [ "$BUILD_SNAPPY" = "yes" ]; then
  echo "  snappy:     1.2.2 $(file "$SYSROOT_PREFIX/lib/libsnappy.a")"
fi
if [ "$BUILD_ZSTD" = "yes" ]; then
  echo "  zstd:       c73288c8 (facebook@dev) $(file "$SYSROOT_PREFIX/lib/libzstd.a")"
fi
if [ "$BUILD_OPENSSL" = "yes" ]; then
  echo "  openssl:    3.6.0 $(file "$SYSROOT_PREFIX/$OPENSSL_LIB_DIR/libssl.a")"
fi
if [ "$BUILD_AWS_LC" = "yes" ]; then
  echo "  aws-lc:     1.72.1 $(file "$SYSROOT_PREFIX/lib/libcrypto.a")"
  echo "                     $(file "$SYSROOT_PREFIX/lib/libcrypto.so")"
fi
if [ "$BUILD_SQLITE" = "yes" ]; then
  echo "  sqlite:     3.51.0 $(file "$SYSROOT_PREFIX/lib/libsqlite3.a")"
fi
if [ "$BUILD_SQLCIPHER" = "yes" ]; then
  echo "  sqlcipher:  4.11.0 $(file "$SYSROOT_PREFIX/sqlcipher/lib/libsqlite3.a")"
fi
if [ "$BUILD_CAPNP" = "yes" ]; then
  echo "  capnp:      v1.3.0 $(file "$SYSROOT_PREFIX/lib/libcapnp.a")"
fi
if [ "$BUILD_HIREDIS" = "yes" ]; then
  echo "  hiredis:    1.3.0 $(file "$SYSROOT_PREFIX/lib/libhiredis.a")"
fi
if [ "$BUILD_CRC32C" = "yes" ]; then
  echo "  crc32c:     1.1.2 $(file "$SYSROOT_PREFIX/lib/libcrc32c.a")"
fi
if [ "$BUILD_LEVELDB" = "yes" ]; then
  echo "  leveldb:    1.23 $(file "$SYSROOT_PREFIX/lib/libleveldb.a")"
fi
if [ "$BUILD_LZ4" = "yes" ]; then
  echo "  lz4:        1.10.0 $(file "$SYSROOT_PREFIX/lib/liblz4.a")"
fi
echo ""
echo "Features:"
echo "  Hardened:       $HARDEN"
echo "  Secure:         $SECURE"
echo "  Guarded:        $GUARDED"
echo "  CFI:            $CFI"
echo "  Mimalloc:       yes"
echo "  Musl+Mimalloc:  $MUSL_USE_MIMALLOC"
echo "  Musl-CrossMake: $USE_MUSL_CROSSMAKE"
echo "  LLVM Projects:  $LLVM_PROJECTS"
echo "  Compiler:       $PREFER_COMPILER_FAMILY"
echo "  sccache:        $USE_SCCACHE"
echo "-----------------------------------------------"

if [ "$MAKE_SYMLINK" != "yes" ]; then
  echo "Skipping symlink creation."
else
  sudo ln -s $HOME/workspace/musl/latest/bin/musl-gcc /usr/bin/x86_64-linux-musl-gcc || echo "Link exists."
fi

exit 0
