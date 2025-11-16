#!/usr/bin/env bash

# Active versions:
# - Musl: 1.2.5 (patched)
# - Mimalloc: 3.1.5
# - OpenSSL: 3.6.0
# - Zlib: Cloudflare Zlib @gcc.amd64
# - SQLite: master branch as of Nov 2025

set -e -x

SECURE=${SECURE:-ON}
GUARDED=${GUARDED:-ON}
CFI=${CFI:-yes}
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
USE_SCCACHE=${USE_SCCACHE:-yes}
MAKE_SYMLINK=${MAKE_SYMLINK:-no}
JOBS=`nproc`
ARCH_FLAVOR=${ARCH_FLAVOR:-amd64}
C_TARGET_ARCH=${C_TARGET_ARCH:-x86-64-v4}
C_TARGET_TUNE=${C_TARGET_TUNE:-znver4}
ROOT_DIR=$PWD

BUILD_ZLIB=${BUILD_ZLIB:-yes}
BUILD_OPENSSL=${BUILD_OPENSSL:-yes}
BUILD_SQLITE=${BUILD_SQLITE:-yes}

unset CC
unset CFLAGS
unset LDFLAGS

rm -fr 1.2.5
mkdir -p 1.2.5/lib 1.2.5/include 1.2.5/bin

mkdir -p ./1.2.5/include/linux
mkdir -p ./1.2.5/include/asm
mkdir -p ./1.2.5/include/asm-generic

# Copy kernel headers (adjust paths for Ubuntu's multiarch layout)
cp -r /usr/include/linux/* ./1.2.5/include/linux/
cp -r /usr/include/asm-generic/* ./1.2.5/include/asm-generic/

# if the ARCH_FLAVOR is amd64, we need to copy from x86_64-linux-gnu
if [ "$ARCH_FLAVOR" = "amd64" ]; then
  cp -r /usr/include/x86_64-linux-gnu/asm/* ./1.2.5/include/asm/
else
  cp -r /usr/include/aarch64-linux-gnu/asm/* ./1.2.5/include/asm/
fi

# Verify you got what you need
ls ./1.2.5/include/linux/mman.h

sudo chown -R $(whoami) ./1.2.5

## Build musl (bootstrap compiler)
echo "------- Building musl (phase 1)...";
pushd musl;

rm -fr mimalloc;

make clean && \
  ./configure \
    --prefix=$ROOT_DIR/1.2.5 \
    --with-malloc=mallocng \
    --enable-optimize=internal,malloc,string \
  && make -j${JOBS} \
    CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects -fno-plt -fstack-protector-strong -fomit-frame-pointer -Wl,-z,relro,-z,now -Wa,--noexecstack" \
    CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects" \
    CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects" \
    ADD_CFI=$CFI \
    | tee buildlog.txt;

make install;
popd;

echo "Smoketesting compiler..."
MUSL_GCC=$ROOT_DIR/1.2.5/bin/musl-gcc
$MUSL_GCC --version;

export CC=$ROOT_DIR/1.2.5/bin/musl-gcc

export CFLAGS="-I$ROOT_DIR/1.2.5/include -I/usr/include/x86_64-linux-musl"
export LDFLAGS="-L$ROOT_DIR/1.2.5/lib"

export CFLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O2 -ffat-lto-objects -fstack-protector-strong -Wl,-z,relro,-z,now -Wa,--noexecstack -D_FORTIFY_SOURCE=2 $CFLAGS"
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
    -DCMAKE_C_FLAGS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -fPIC -O3 -ffat-lto-objects" \
    -DCMAKE_INSTALL_PREFIX=$ROOT_DIR/1.2.5 \
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

if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
  cp -fv ../mimalloc/out/release/mimalloc*.o ./mimalloc/objs/;
else
  echo "Not using mimalloc in musl build.";
fi

# patch for mimalloc
# if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
#   git apply ./patches/patch-3-elide-1.patch
# fi

make clean && \
  ./configure \
    --prefix=$ROOT_DIR/1.2.5 \
    --enable-optimize=internal,malloc,string \
  && make -j${JOBS} \
    CFLAGS_AUTO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects -fno-plt -fstack-protector-strong -fomit-frame-pointer -Wl,-z,relro,-z,now" \
    CFLAGS_MEMOPS="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects" \
    CFLAGS_LDSO="-march=$C_TARGET_ARCH -mtune=$C_TARGET_TUNE -O3 -ffat-lto-objects" \
    USE_MIMALLOC=$MUSL_USE_MIMALLOC \
    ADD_CFI=$CFI \
    | tee buildlog.txt;

make install;

# if [ "$MUSL_USE_MIMALLOC" = "yes" ]; then
#   # un-patch
#   git checkout .;
# fi
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
    --prefix=$ROOT_DIR/1.2.5 \
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

  # no-shared \
  # no-tests \
  # no-external-tests \
  # no-async \
  # no-zlib \
  # no-comp \
  # no-asm \
  # no-secure-memory \

  ./Configure \
      linux-x86_64 \
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
      --prefix=$ROOT_DIR/1.2.5 \
      --openssldir=$ROOT_DIR/1.2.5/ssl \
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
    --prefix=$ROOT_DIR/1.2.5 \
    --enable-all \
    --enable-static \
    --enable-fts5 \
    --enable-threadsafe \
    --disable-shared;

  make -j$JOBS | tee buildlog.txt;
  make install;
  popd;
fi

set +x -e
sleep 1

echo "Verifying..."
file $ROOT_DIR/1.2.5/bin/musl-gcc || exit 2
file $ROOT_DIR/1.2.5/lib/libc.a || exit 2
file $ROOT_DIR/1.2.5/lib/libz.a || exit 3
file $ROOT_DIR/1.2.5/lib64/libssl.a || exit 4

# Check that AVX-512 instructions are being used
# objdump -d $ROOT_DIR/1.2.5/lib/libcrypt.a | grep -i "vpadd\|vpxor\|vaes" || exit 5

# Verify stack protection
# readelf -s $ROOT_DIR/1.2.5/lib/libcrypt.a | grep stack_chk || exit 6

echo "Verification complete."

echo "Build complete."
echo "-----------------------------------------------"
echo "Musl Sysroot (1.2.5-patched.2):"
echo "  Location: $ROOT_DIR/1.2.5"
echo "  Compiler: $MUSL_GCC"
echo "  Arch:     $TARGET_ARCH"
echo ""
echo "Compiler flags:"
echo "  CFLAGS:   -I$ROOT_DIR/1.2.5/include"
echo "  LDFLAGS:  -L$ROOT_DIR/1.2.5/lib -static"
echo "  CC:       $ROOT_DIR/1.2.5/bin/musl-gcc"
echo "  CFLAGS:   $CFLAGS"
echo "  LDFLAGS:  $LDFLAGS"
echo ""
echo "Components:"
echo "  mimalloc:   3.1.5"
echo "  libc:       $(file $ROOT_DIR/1.2.5/lib/libc.a)"
if [ "$BUILD_ZLIB" = "yes" ]; then
  echo "  zlib:       (cloudflare@gcc.amd64) $(file $ROOT_DIR/1.2.5/lib/libz.a)"
fi
if [ "$BUILD_OPENSSL" = "yes" ]; then
  echo "  openssl:    3.6.0 $(file $ROOT_DIR/1.2.5/lib64/libssl.a)"
fi
if [ "$BUILD_SQLITE" = "yes" ]; then
  echo "  sqlite:     master $(file $ROOT_DIR/1.2.5/lib/libsqlite3.a)"
fi
echo ""
echo "Features:"
echo "  Secure:         $SECURE"
echo "  Guarded:        $GUARDED"
echo "  CFI:            $CFI"
echo "  Mimalloc:       yes"
echo "  Musl+Mimalloc:  $MUSL_USE_MIMALLOC"
echo "-----------------------------------------------"

if [ "$MAKE_SYMLINK" != "yes" ]; then
  echo "Skipping symlink creation.";
  exit 0;
else
  sudo ln -s $HOME/workspace/musl/latest/bin/musl-gcc /usr/bin/x86_64-linux-musl-gcc || echo "Link exists."
fi

exit 0
