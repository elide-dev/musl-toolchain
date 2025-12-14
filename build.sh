#!/usr/bin/env bash

# Active versions:
# - Brotli: 1.2.0
# - CRC32C: 1.1.2
# - Hiredis: 1.3.0
# - LevelDB: 1.23
# - LLVM: 21.1.2
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

## Settings.
RELEASE=${RELEASE:-no}
HARDEN=${HARDEN:-yes}
SECURE=${SECURE:-OFF}
GUARDED=${GUARDED:-OFF}
CFI=${CFI:-no}
MPK=${MPK:-no}
LLVM_PROJECTS="clang;lld"

## Advanced settings.
USE_MUSL_CROSSMAKE=${USE_MUSL_CROSSMAKE:-yes}
USE_SCCACHE=${USE_SCCACHE:-yes}
USE_LTO=${USE_LTO:-no}
USE_WIDE_VECTORS=${USE_WIDE_VECTORS:-no}
CLEAN_BEFORE_BUILD=${CLEAN_BEFORE_BUILD:-yes}
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
MAKE_SYMLINK=${MAKE_SYMLINK:-no}

MODERN_X86_64_ARCH_TARGET=x86-64-v3
MODERN_X86_64_ARCH_TUNE=znver3
MODERN_AARCH64_ARCH_TARGET=armv8.4-a+crypto+crc
MODERN_AARCH64_ARCH_TUNE=neoverse-v1

JOBS=`nproc`
ARCH_FLAVOR=${ARCH_FLAVOR:-amd64}
ROOT_DIR=$PWD

MUSL_VERSION=1.2.5
SYSROOT_PREFIX="$ROOT_DIR/$MUSL_VERSION"

OPT_CFLAGS="-O2 -ffat-lto-objects -fno-semantic-interposition"
SECURITY_CFLAGS="-fno-plt -fstack-protector-strong -fstack-clash-protection -fomit-frame-pointer -D_FORTIFY_SOURCE=2 -Wa,--noexecstack"
OPT_LDFLAGS=""
SECURITY_LDFLAGS="-Wl,-z,relro,-z,now,-z,separate-code"
LTO_CFLAGS="-flto=auto"

unset CC
unset CFLAGS
unset LDFLAGS

source ./vars.sh || echo "No vars; using defaults."

echo "-----------------------------------------------"
echo "Musl toolchain:"
echo "BUILD_BROTLI=$BUILD_BROTLI"
echo "BUILD_CAPNP=$BUILD_CAPNP"
echo "BUILD_CRC32C=$BUILD_CRC32C"
echo "BUILD_HIREDIS=$BUILD_HIREDIS"
echo "BUILD_LEVELDB=$BUILD_LEVELDB"
echo "BUILD_LLVM=$BUILD_LLVM"
echo "BUILD_OPENSSL=$BUILD_OPENSSL"
echo "BUILD_SNAPPY=$BUILD_SNAPPY"
echo "BUILD_SQLCIPHER=$BUILD_SQLCIPHER"
echo "BUILD_SQLITE=$BUILD_SQLITE"
echo "BUILD_STAGE2=$BUILD_STAGE2"
echo "BUILD_ZLIB_NG=$BUILD_ZLIB_NG"
echo "BUILD_ZLIB=$BUILD_ZLIB"
echo "BUILD_ZSTD=$BUILD_ZSTD"
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
echo "-----------------------------------------------"
echo "Bulding starting in 3 seconds..."
sleep 1
echo "2..."
sleep 1
echo "1..."
sleep 1

echo "Symlinking 'latest'...";
ln -s "$MUSL_VERSION" latest;

set -e -o pipefail -x

# if musl version is empty, fail
if [ -z "$MUSL_VERSION" ]; then
  echo "MUSL_VERSION is not set. Exiting.";
  exit 1;
fi
if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
  echo "Cleaning previous build at $MUSL_VERSION ..."
  rm -fr "$MUSL_VERSION"
fi

mkdir -p "$MUSL_VERSION/lib" "$MUSL_VERSION/include" "$MUSL_VERSION/bin"

mkdir -p ./"$MUSL_VERSION/include/linux"
mkdir -p ./"$MUSL_VERSION/include/asm"
mkdir -p ./"$MUSL_VERSION/include/asm-generic"

# Copy kernel headers (adjust paths for Ubuntu's multiarch layout)
cp -r /usr/include/linux/* "./$MUSL_VERSION/include/linux/"
cp -r /usr/include/asm-generic/* "./$MUSL_VERSION/include/asm-generic/"

# if the ARCH_FLAVOR is amd64, we need to copy from x86_64-linux-musl
if [ "$ARCH_FLAVOR" = "amd64" ]; then
  ARCH_FLAVOR="x86_64";
  MUSL_TARGET="x86_64-linux-musl"
  LINUX_ARCH_DIR="x86_64-linux-musl"
  C_TARGET_ARCH=${C_TARGET_ARCH:-$MODERN_X86_64_ARCH_TARGET}
  C_TARGET_TUNE=${C_TARGET_TUNE:-$MODERN_X86_64_ARCH_TUNE}
  if [ "$USE_WIDE_VECTORS" = "yes" ]; then
    OPT_CFLAGS="$OPT_CFLAGS -mavx512f -mavx512bw -mavx512dq -mavx512vl"
  fi
  SECURITY_CFLAGS="$SECURITY_CFLAGS -fcf-protection=branch"
  if [ "$CFI" = "yes" ]; then
    SECURITY_CFLAGS="$SECURITY_CFLAGS -fcf-protection=full $([ "$MPK" = "yes" ] && echo "-mpku")"
  fi
  # Specifically copy asm headers from x86_64-linux-gnu, since musl does not have them
  cp -r /usr/include/x86_64-linux-gnu/asm/* "./$MUSL_VERSION/include/asm/"
  pushd "$MUSL_VERSION/bin";
  # create symlink if it does not exist
  if [ ! -f x86_64-linux-musl-gcc ]; then
    ln -s musl-gcc x86_64-linux-musl-gcc;
  fi
  popd;
elif [ "$ARCH_FLAVOR" = "arm64" ]; then
  ARCH_FLAVOR="aarch64";
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
  pushd "$MUSL_VERSION/bin";
  ln -s musl-gcc "$ARCH_FLAVOR-linux-musl-gcc";
  popd;
else
  echo "Unsupported ARCH_FLAVOR: $ARCH_FLAVOR";
  exit 1;
fi

ls "./$MUSL_VERSION/include/linux/mman.h"

sudo chown -R $(whoami) "./$MUSL_VERSION"

## Build musl (bootstrap compiler)
echo "------- Building musl (phase 1)...";
pushd musl;

rm -fr mimalloc;
make distclean || true
rm -f config.mak

make clean;
./configure \
  --prefix="$SYSROOT_PREFIX" \
  --with-malloc=mallocng \
  --enable-optimize=internal,malloc,string
make -j${JOBS} \
  CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
  CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
  CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
  ADD_CFI=$CFI \
  | tee buildlog.txt;

# Debug: Check detected architecture
echo "=== Musl Configuration ==="
grep "^ARCH" config.mak
echo "Expected: ARCH = $(uname -m)"
echo "=========================="

make install;
popd;

echo "Smoketesting compiler..."
MUSL_GCC="$SYSROOT_PREFIX/bin/musl-gcc"
$MUSL_GCC --version;

if [ "$USE_MUSL_CROSSMAKE" = "yes" ]; then
  ## Build musl (bootstrap compiler)
  echo "------- Building musl-cross-make...";

  cp -fv config.mak musl-cross-make/config.mak
  pushd musl-cross-make;

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    make clean || echo "Nothing to clean.";
  fi

  echo "Building 'musl-cross-make'..."

  make -j${JOBS} \
    MUSL_ARCH="$ARCH_FLAVOR" \
    OUTPUT="$SYSROOT_PREFIX" \
    TARGET=$MUSL_TARGET \
    TUNE=$C_TARGET_TUNE \
    TARGET_MARCH=$C_TARGET_ARCH \
    SECURITY_CFLAGS="$SECURITY_CFLAGS" \
    HARDEN=$HARDEN \
    CFI=$CFI \
    MPK=$MPK \
    install 2>&1 > buildlog.txt;

  popd;
  ####
fi

export CC="$SYSROOT_PREFIX/bin/musl-gcc"

export CFLAGS="-I$SYSROOT_PREFIX/include -I/usr/include/$LINUX_ARCH_DIR -march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS $CFLAGS"
export LDFLAGS="-L$SYSROOT_PREFIX/lib -L$SYSROOT_PREFIX/lib64 $OPT_LDFLAGS $SECURITY_LDFLAGS"

# Add LDFLAGS here if needed.
# export LDFLAGS="$LDFLAGS"

## Build mimalloc
echo "------- Building mimalloc...";
pushd mimalloc;
rm -fr out/release;
mkdir -p out/release;
pushd out/release;

cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DMI_SECURE=$SECURE \
    -DMI_GUARDED=$GUARDED \
    -DMI_LIBC_MUSL=OFF \
    -DMI_OPT_ARCH=ON \
    -DMI_SEE_ASM=ON \
    -DMI_LIBC_MUSL=ON \
    -DMI_BUILD_SHARED=OFF \
    -DMI_BUILD_STATIC=ON \
    -DMI_EXTRA_CPPDEFS="MI_DEFAULT_ARENA_RESERVE=33554432;MI_DEFAULT_ALLOW_LARGE_OS_PAGES=0" \
    -DMI_SKIP_COLLECT_ON_EXIT=1 \
    -DCMAKE_C_COMPILER_LAUNCHER=sccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=sccache \
    -DCMAKE_C_COMPILER=$CC \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -fPIC -O3 -ffat-lto-objects $SECURITY_CFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    ../..;
make -j${JOBS} | tee buildlog.txt;
make install;
popd;
popd;
echo "Mimalloc done."

## Build musl (phase 2 + mimalloc)
if [ "$BUILD_STAGE2" = "yes" ]; then
  echo "------- Building musl (phase 2)...";
  pushd musl;

  mkdir -p mimalloc/objs;
  rm -fv buildlog.txt mimalloc/objs/*;
  rm -f config.mak
  make distclean || true

  if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
    cp -fv ../mimalloc/out/release/mimalloc*.o ./mimalloc/objs/;
  else
    echo "Not using mimalloc in musl build.";
  fi

  make clean;
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --enable-optimize=internal,malloc,string;

  make -j${JOBS} \
    CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    USE_MIMALLOC=$MUSL_USE_MIMALLOC \
    ADD_CFI=$CFI \
    | tee buildlog.txt;

  make install;

  popd;
fi

## Mount musl sysroot

CC_NO_PREFIX="$MUSL_GCC"
CXX_NO_PREFIX="$MUSL_GCC"

if [ "$USE_SCCACHE" = "yes" ]; then
  export CC="`which sccache` $MUSL_GCC"
  export CXX="`which sccache` $MUSL_GCC"
else
  export CC="$MUSL_GCC"
  export CXX="$MUSL_GCC"
fi

export CFLAGS="$CFLAGS -O3"
export LDFLAGS="$LDFLAGS -static"

if [ "$USE_LTO" = "yes" ]; then
  export CFLAGS="$CFLAGS $LTO_CFLAGS"
  export LDFLAGS="$LDFLAGS $LTO_CFLAGS"
fi

## Build zlib

if [ "$BUILD_ZLIB" != "yes" ]; then
  echo "Skipping zlib build.";
else
  echo "------- Building zlib...";
  pushd zlib;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean.";
  fi
  if [ "$ARCH_FLAVOR" = "x86_64" ]; then
    ZLIB_FLAGS="--64"
  else
    ZLIB_FLAGS=""
  fi

  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --const \
    --static \
    $ZLIB_FLAGS;
  make -j${JOBS};
  make install;
  popd;
fi

## Build zlib-ng

if [ "$BUILD_ZLIB_NG" != "yes" ]; then
  echo "Skipping zlib-ng build.";
else
  echo "------- Building zlib-ng...";
  pushd zlib-ng;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean.";
  fi

  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --static;
  make -j${JOBS};
  make install;
  popd;
fi

### Build zstd

if [ "$BUILD_ZSTD" != "yes" ]; then
  echo "Skipping zstd build.";
else
  echo "------- Building zstd...";
  pushd zstd;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake;
    make clean || echo "Nothing to clean.";
  fi
  cmake -S . -B build-cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_MULTITHREAD_SUPPORT=ON;
  cmake --build build-cmake;
  cmake --install build-cmake;

  popd;
fi

## Build brotli
if [ "$BUILD_BROTLI" != "yes" ]; then
  echo "Skipping brotli build.";
else
  echo "------- Building brotli...";
  pushd brotli;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake;
    make clean || echo "Nothing to clean.";
  fi
  cmake -S . -B build-cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DBUILD_SHARED_LIBS=OFF;
  cmake --build build-cmake;
  cmake --install build-cmake;

  popd;
fi

## Build Snappy
if [ "$BUILD_SNAPPY" != "yes" ]; then
  echo "Skipping snappy build.";
else
  echo "------- Building snappy...";
  pushd snappy;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    rm -fr build-cmake;
    make clean || echo "Nothing to clean.";
  fi
  mkdir -p build-cmake;
  pushd build-cmake;
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++" \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DCMAKE_CXX_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DSNAPPY_BUILD_TESTS=OFF \
    -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DBUILD_SHARED_LIBS=OFF;
  make -j${JOBS};
  make install;
  popd;
  popd;
fi

### Build LLVM
if [ "$BUILD_LLVM" != "yes" ]; then
  echo "Skipping LLVM build.";
else
  echo "------- Building LLVM...";
  pushd llvm;

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    echo "Cleaning previous LLVM build ..."
    rm -fr build
    git checkout .
    git clean -xdf
  fi

  mkdir -p build;
  popd;
  pushd llvm/build;
  cmake ../llvm \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++" \
    -DCMAKE_C_COMPILER_LAUNCHER=$(which sccache) \
    -DCMAKE_CXX_COMPILER_LAUNCHER=$(which sccache) \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_TOOL_BOLT_BUILD=TRUE \
    -DLLVM_TOOL_CLANG_BUILD=TRUE \
    -DLLVM_BUILD_32_BITS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_BUILD_BENCHMARKS=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_ENABLE_PIC=OFF \
    -DLLVM_BUILD_STATIC=ON \
    -DLLVM_ENABLE_ZLIB=ON \
    -DLLVM_ENABLE_ZSTD=ON \
    -DLLVM_ENABLE_RPMALLOC=ON \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$MUSL_TARGET" \
    -DLIBCLANG_BUILD_STATIC=ON \
    -DCLANG_LINK_CLANG_DYLIB=OFF \
    -DCMAKE_SYSROOT="$SYSROOT_PREFIX/$LINUX_ARCH_DIR" \
    -DCMAKE_FIND_ROOT_PATH="$SYSROOT_PREFIX" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DZLIB_INCLUDE_DIR="$SYSROOT_PREFIX/include" \
    -DZLIB_LIBRARY="$SYSROOT_PREFIX/lib/libz.a" \
    -Dzstd_INCLUDE_DIR="$SYSROOT_PREFIX/include" \
    -Dzstd_LIBRARY="$SYSROOT_PREFIX/lib/libzstd.a" \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-L$SYSROOT_PREFIX/$LINUX_ARCH_DIR/lib -latomic" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$SYSROOT_PREFIX/$LINUX_ARCH_DIR/lib -latomic" \
    -DCMAKE_MODULE_LINKER_FLAGS="-L$SYSROOT_PREFIX/$LINUX_ARCH_DIR/lib -latomic" \
    -DLLVM_INTEGRATED_CRT_ALLOC=OFF \
    -DLLVM_ENABLE_RTTI=ON;
  make -j${JOBS};
  make install;
  echo "LLVM build complete.";
  sleep 3;
  popd;
fi

### Build openssl

if [ "$BUILD_OPENSSL" != "yes" ]; then
  echo "Skipping openssl build.";
else
  echo "------- Building openssl...";
  pushd openssl;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step";
  fi
  rm -fv buildlog.txt;
  export CFLAGS="$CFLAGS -fPIE -fPIC"

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
      CC="$CC" \
      CXX="$CXX";

  make -j$JOBS depend
  make -j$JOBS | tee buildlog.txt;
  make install_sw install_ssldirs;
  popd;
fi

### Build sqlite

if [ "$BUILD_SQLITE" != "yes" ]; then
  echo "Skipping sqlite build.";
else
  echo "------- Building sqlite...";
  pushd sqlite;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step";
  fi
  rm -fv buildlog.txt;

  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
    --with-tempstore=yes \
    --disable-tcl \
    --disable-shared;

  make -j$JOBS | tee buildlog.txt;
  make install;
  popd;
fi

### Build sqlcipher

if [ "$BUILD_SQLCIPHER" != "yes" ]; then
  echo "Skipping sqlcipher build.";
else
  echo "------- Building sqlcipher...";
  pushd sqlcipher;
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "No clean step";
  fi
  rm -fv buildlog.txt;

  ./configure \
    CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown $CFLAGS" \
    LDFLAGS="$LDFLAGS -lcrypto" \
    --prefix="$SYSROOT_PREFIX/sqlcipher" \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
    --with-tempstore=yes \
    --disable-tcl \
    --disable-shared;

  make -j$JOBS | tee buildlog.txt;
  make install;
  popd;
fi

### Build capnp

if [ "$BUILD_CAPNP" != "yes" ]; then
  echo "Skipping capnp build.";
else
  echo "------- Building capnp...";

  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    make clean || echo "Nothing to clean.";
  fi

  cd capnp/c++;
  autoreconf -i;
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --with-zlib \
    --with-openssl \
    --with-sysroot="$SYSROOT_PREFIX";
  make -j${JOBS} check
  make install
  cd -;
fi

### Build hiredis

if [ "$BUILD_HIREDIS" != "yes" ]; then
  echo "Skipping hiredis build.";
else
  pushd hiredis;
  echo "------- Building hiredis...";
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean.";
  fi
  make \
    -j${JOBS} \
    USE_SSL=1 \
    CFLAGS="-Wno-error=stringop-overflow $CFLAGS" \
    PREFIX="$SYSROOT_PREFIX" \
    OPTIMIZATION=-O3 \
    static pkgconfig install \
    | tee buildlog.txt;
  popd;
fi

### CRC32C
if [ "$BUILD_CRC32C" != "yes" ]; then
  echo "Skipping crc32c build.";
else
  git submodule update --init --depth=1 --recursive crc32c;
  pushd crc32c;
  echo "------- Building crc32c...";
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean.";
  fi

  mkdir -p build;
  pushd build;
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++" \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DCMAKE_CXX_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DBUILD_SHARED_LIBS=0 \
    -DCRC32C_BUILD_TESTS=0 \
    -DCRC32C_BUILD_BENCHMARKS=0;
  make -j${JOBS};
  make install;
  popd;
  popd;
fi

### Build leveldb

if [ "$BUILD_LEVELDB" != "yes" ]; then
  echo "Skipping leveldb build.";
else
  pushd leveldb;
  echo "------- Building leveldb...";
  if [ "$CLEAN_BEFORE_BUILD" = "yes" ]; then
    git checkout .
    git clean -xdf
    make clean || echo "Nothing to clean.";
  fi

  mkdir -p build;
  pushd build;
  cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DLEVELDB_BUILD_TESTS=OFF \
    -DLEVELDB_BUILD_BENCHMARKS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT_PREFIX" \
    -DCMAKE_C_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-gcc" \
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3" \
    -DCMAKE_CXX_COMPILER="$SYSROOT_PREFIX/bin/${MUSL_TARGET}-g++" \
    -DCMAKE_CXX_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE $OPT_CFLAGS $SECURITY_CFLAGS -O3";
  make -j${JOBS};
  make install;
  popd;
  popd;
fi

### ======= Done.

set +x -e
sleep 1

echo "Verifying..."
file "$SYSROOT_PREFIX/bin/musl-gcc" || exit 2
file "$SYSROOT_PREFIX/lib/libc.a" || exit 2
file "$SYSROOT_PREFIX/lib/libz.a" || exit 3

if [ "$ARCH_FLAVOR" = "x86_64" ]; then
  OPENSSL_LIB_DIR="lib64"
else
  OPENSSL_LIB_DIR="lib"
fi

file "$SYSROOT_PREFIX/$OPENSSL_LIB_DIR/libssl.a" || exit 4

echo "Verification complete."

echo "Build complete."
echo "-----------------------------------------------"
echo "Musl Sysroot (${MUSL_VERSION}+p3):"
echo "  Location: $SYSROOT_PREFIX"
echo "  Compiler: $MUSL_GCC"
echo "  Arch:     $C_TARGET_ARCH"
echo "  Tune:     $C_TARGET_TUNE"
echo ""
echo "Compiler flags:"
echo "  CFLAGS:   -I$SYSROOT_PREFIX/include"
echo "  LDFLAGS:  -L$SYSROOT_PREFIX/lib -static"
echo "  CC:       $SYSROOT_PREFIX/bin/musl-gcc"
echo "  CFLAGS:   $CFLAGS"
echo "  LDFLAGS:  $LDFLAGS"
echo ""
echo "Components:"
echo "  mimalloc:   3.1.5"
echo "  libc:       1.2.5+p3 $(file "$SYSROOT_PREFIX/lib/libc.a")"
if [ "$BUILD_LLVM" = "yes" ]; then
  echo "  llvm:       21.1.2 $(file "$SYSROOT_PREFIX/bin/clang")"
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
echo "-----------------------------------------------"

if [ "$MAKE_SYMLINK" != "yes" ]; then
  echo "Skipping symlink creation.";
else
  sudo ln -s $HOME/workspace/musl/latest/bin/musl-gcc /usr/bin/x86_64-linux-musl-gcc || echo "Link exists."
fi

exit 0
