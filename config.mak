#
# config.mak.dist - toolchain musl-cross-make configuration
#

MUSL_ARCH ?= x86_64
TARGET ?= $(MUSL_ARCH)-linux-musl
TUNE ?= generic

ifeq ($(MUSL_ARCH),x86_64)
TARGET_MARCH ?= x86-64-v4
endif
ifeq ($(MUSL_ARCH),arm64)
TARGET_MARCH ?= armv8.4-a+crypto+sve
endif

BINUTILS_VER = 2.44
GCC_VER = 14.2.0
MUSL_VER = 1.2.5
GMP_VER = 6.3.0
MPC_VER = 1.3.1
MPFR_VER = 4.2.2
ISL_VER = 0.27
LINUX_VER = 6.15.7

COMMON_CONFIG += CFLAGS="-g0 -O2 -ffat-lto-objects -march=$(TARGET_MARCH) -mtune=$(TUNE) -fstack-protector-strong -Wl,-z,relro,-z,now -Wa,--noexecstack -D_FORTIFY_SOURCE=2"
COMMON_CONFIG += CXXFLAGS="-g0 -O2 -ffat-lto-objects -march=$(TARGET_MARCH) -mtune=$(TUNE) -fstack-protector-strong -Wl,-z,relro,-z,now -Wa,--noexecstack -D_FORTIFY_SOURCE=2"
COMMON_CONFIG += LDFLAGS="-s -ffat-lto-objects -Wl,-z,relro,-z,now,-z,noexecstack"

# COMMON_CONFIG += --disable-nls
# GCC_CONFIG += --disable-libquadmath --disable-decimal-float
# GCC_CONFIG += --disable-libitm
# GCC_CONFIG += --disable-fixed-point
# GCC_CONFIG += --disable-lto
# GCC_CONFIG += --enable-languages=c,c++
# COMMON_CONFIG += --with-debug-prefix-map=$(CURDIR)=
