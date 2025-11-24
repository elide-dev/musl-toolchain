#!/usr/bin/env bash

# Active versions:
# - Musl: 1.2.5 (patched)
# - Mimalloc: 3.1.5
# - OpenSSL: 3.6.0
# - Zlib: Cloudflare Zlib @gcc.amd64
# - SQLite: 3.51.0
# - LLVM: 21.1.2

set -e -x

HARDEN=${HARDEN:-yes}
SECURE=${SECURE:-OFF}
GUARDED=${GUARDED:-OFF}
CFI=${CFI:-no}
MPK=${MPK:-no}
CLEAN_BEFORE_BUILD=${CLEAN_BEFORE_BUILD:-no}
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
USE_MUSL_CROSSMAKE=${USE_MUSL_CROSSMAKE:-yes}
USE_SCCACHE=${USE_SCCACHE:-yes}
MAKE_SYMLINK=${MAKE_SYMLINK:-no}
JOBS=`nproc`
ARCH_FLAVOR=${ARCH_FLAVOR:-amd64}
C_TARGET_ARCH=${C_TARGET_ARCH:-x86-64-v4}
C_TARGET_TUNE=${C_TARGET_TUNE:-znver3}
ROOT_DIR=$PWD

MUSL_VERSION=1.2.5
SYSROOT_PREFIX="$ROOT_DIR/$MUSL_VERSION"

BUILD_ZLIB=${BUILD_ZLIB:-yes}
BUILD_OPENSSL=${BUILD_OPENSSL:-yes}
BUILD_SQLITE=${BUILD_SQLITE:-yes}
BUILD_CAPNP=${BUILD_CAPNP:-no}

unset CC
unset CFLAGS
unset LDFLAGS

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
SECURITY_CFLAGS=""

# if the ARCH_FLAVOR is amd64, we need to copy from x86_64-linux-musl
if [ "$ARCH_FLAVOR" = "amd64" ]; then
  ARCH_FLAVOR="x86_64";
  MUSL_TARGET="x86_64-linux-musl"
  LINUX_ARCH_DIR="x86_64-linux-musl"
  SECURITY_CFLAGS="$SECURITY_CFLAGS"
  if [ "$CFI" = "yes" ]; then
    SECURITY_CFLAGS="$SECURITY_CFLAGS -fcf-protection=full $([ "$MPK" = "yes" ] && echo "-mpku")"
  fi
  # Specifically copy asm headers from x86_64-linux-gnu, since musl does not have them
  cp -r /usr/include/x86_64-linux-gnu/asm/* "./$MUSL_VERSION/include/asm/"
  pushd "$MUSL_VERSION/bin";
  ln -s musl-gcc x86_64-linux-musl-gcc;
  popd;
else if [ "$ARCH_FLAVOR" = "arm64" ]; then
  ARCH_FLAVOR="aarch64";
  MUSL_TARGET="$ARCH_FLAVOR-linux-musl"
  LINUX_ARCH_DIR="$ARCH_FLAVOR-linux-musl"
  SECURITY_CFLAGS="$SECURITY_CFLAGS -mbranch-protection=standard"
  cp -r /usr/include/$ARCH_FLAVOR-linux-gnu/asm/* "./$MUSL_VERSION/include/asm/"
  pushd "$MUSL_VERSION/bin";
  ln -s musl-gcc "$ARCH_FLAVOR-linux-musl-gcc";
  popd;
else
  echo "Unsupported ARCH_FLAVOR: $ARCH_FLAVOR";
  exit 1;
fi
fi

# Verify you got what you need
ls "./$MUSL_VERSION/include/linux/mman.h"

sudo chown -R $(whoami) "./$MUSL_VERSION"

## Build musl (bootstrap compiler)
echo "------- Building musl (phase 1)...";
pushd musl;

rm -fr mimalloc;
make distclean || true
rm -f config.mak

make clean && \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --with-malloc=mallocng \
    --enable-optimize=internal,malloc,string \
  && make -j${JOBS} \
    CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects -fno-plt -fstack-protector-strong -fomit-frame-pointer -Wl,-z,relro,-z,now -Wa,--noexecstack $SECURITY_CFLAGS" \
    CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects $SECURITY_CFLAGS" \
    CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects $SECURITY_CFLAGS" \
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

  make clean || echo "Nothing to clean.";

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
    install | tee buildlog.txt;

  popd;
  ####
fi

export CC="$SYSROOT_PREFIX/bin/musl-gcc"

export CFLAGS="-I$SYSROOT_PREFIX/include -I/usr/include/$LINUX_ARCH_DIR"
export LDFLAGS="-L$SYSROOT_PREFIX/lib"

export CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O2 -ffat-lto-objects -fstack-protector-strong -Wl,-z,relro,-z,now -Wa,--noexecstack -D_FORTIFY_SOURCE=2 $SECURITY_CFLAGS $CFLAGS"
export LDFLAGS="-ffat-lto-objects $LDFLAGS"

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
    -DMI_BUILD_SHARED=OFF \
    -DMI_BUILD_STATIC=ON \
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

make clean && \
  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --enable-optimize=internal,malloc,string \
  && make -j${JOBS} \
    CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects -fno-plt -fstack-protector-strong -fomit-frame-pointer -Wl,-z,relro,-z,now $SECURITY_CFLAGS" \
    CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects $SECURITY_CFLAGS" \
    CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects $SECURITY_CFLAGS" \
    USE_MIMALLOC=$MUSL_USE_MIMALLOC \
    ADD_CFI=$CFI \
    | tee buildlog.txt;

make install;

popd;

## Mount musl sysroot

if [ "$USE_SCCACHE" = "yes" ]; then
  export CC="`which sccache` $MUSL_GCC"
  export CXX="`which sccache` $MUSL_GCC"
else
  export CC="$MUSL_GCC"
  export CXX="$MUSL_GCC"
fi

export CFLAGS="$CFLAGS -flto=auto"
export LDFLAGS="$LDFLAGS -flto=auto -static -Wl,-z,relro,-z,now,-z,noexecstack"

## Build zlib

if [ "$BUILD_ZLIB" != "yes" ]; then
  echo "Skipping zlib build.";
else
  echo "------- Building zlib...";
  pushd zlib;
  git checkout .
  git clean -xdf
  make clean || echo "Nothing to clean.";
  ./configure \
    --const \
    --64 \
    --static \
    --prefix="$SYSROOT_PREFIX" \
    && make -j${JOBS} \
    && make install
  popd;
fi

### Build openssl

if [ "$BUILD_OPENSSL" != "yes" ]; then
  echo "Skipping openssl build.";
else
  echo "------- Building openssl...";
  pushd openssl;
  git checkout .
  git clean -xdf
  make clean || echo "No clean step";
  rm -fv buildlog.txt;
  export CFLAGS="$CFLAGS -fPIE -fPIC"

  if [ "$ARCH_FLAVOR" = "amd64" ]; then
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
      no-asm \
      no-afalgeng \
      enable-ec_nistp_64_gcc_128 \
      enable-tls1_3 \
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
  git checkout .
  git clean -xdf
  make clean || echo "No clean step";
  rm -fv buildlog.txt;

  ./configure \
    --prefix="$SYSROOT_PREFIX" \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
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

set +x -e
sleep 1

echo "Verifying..."
file "$SYSROOT_PREFIX/bin/musl-gcc" || exit 2
file "$SYSROOT_PREFIX/lib/libc.a" || exit 2
file "$SYSROOT_PREFIX/lib/libz.a" || exit 3

if [ "$ARCH_FLAVOR" = "amd64" ]; then
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
echo "  libc:       $(file "$SYSROOT_PREFIX/lib/libc.a")"
if [ "$BUILD_ZLIB" = "yes" ]; then
  echo "  zlib:       (cloudflare@gcc.amd64) $(file "$SYSROOT_PREFIX/lib/libz.a")"
fi
if [ "$BUILD_OPENSSL" = "yes" ]; then
  echo "  openssl:    3.6.0 $(file "$SYSROOT_PREFIX/lib64/libssl.a")"
fi
if [ "$BUILD_SQLITE" = "yes" ]; then
  echo "  sqlite:     3.51.0 $(file "$SYSROOT_PREFIX/lib/libsqlite3.a")"
fi
if [ "$BUILD_CAPNP" = "yes" ]; then
  echo "  capnp:      v1.3.0 $(file "$SYSROOT_PREFIX/lib/libcapnp.a")"
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
echo "-----------------------------------------------"

if [ "$MAKE_SYMLINK" != "yes" ]; then
  echo "Skipping symlink creation.";
  exit 0;
else
  sudo ln -s $HOME/workspace/musl/latest/bin/musl-gcc /usr/bin/x86_64-linux-musl-gcc || echo "Link exists."
fi

exit 0
