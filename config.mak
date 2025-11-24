#
# config.mak - toolchain musl-cross-make configuration
#

## Settings.
MUSL_ARCH ?= x86_64
TARGET ?= $(MUSL_ARCH)-linux-musl
TUNE ?= generic
HARDEN ?= yes
FORTIFY_LEVEL ?= 3

## Versions.
BINUTILS_VER = 2.44
GCC_VER = 15.2.0
MUSL_VER = 1.2.5
GMP_VER = 6.3.0
MPC_VER = 1.3.1
MPFR_VER = 4.2.2
ISL_VER = 0.27
LINUX_VER = 6.15.7

BASE_SECURITY_FLAGS_LD ?=-Wl,-z,relro,-z,now -Wa,--noexecstack
BASE_SECURITY_FLAGS ?=-mpku -fstack-protector-strong -D_FORTIFY_SOURCE=$(FORTIFY_LEVEL) $(BASE_SECURITY_FLAGS_LD)

ifeq ($(MUSL_ARCH),x86_64)
TARGET_MARCH ?= x86-64-v4
ifeq ($(HARDEN),yes)
SECURITY_FLAGS ?=-fcf-protection=full $(BASE_SECURITY_FLAGS)
SECURITY_FLAGS_LD ?=$(BASE_SECURITY_FLAGS_LD)
else
SECURITY_FLAGS ?=
SECURITY_FLAGS_LD ?=
endif
endif
ifeq ($(MUSL_ARCH),arm64)
TARGET_MARCH ?= armv8.4-a+crypto+sve
ifeq ($(HARDEN),yes)
SECURITY_FLAGS ?=-mbranch-protection=standard $(BASE_SECURITY_FLAGS)
SECURITY_FLAGS_LD ?=$(BASE_SECURITY_FLAGS_LD)
else
SECURITY_FLAGS ?=
SECURITY_FLAGS_LD ?=
endif
endif

COMMON_CONFIG += CFLAGS="-g0 -O2 -ffat-lto-objects -march=$(TARGET_MARCH) -mtune=$(TUNE) $(SECURITY_FLAGS)"
COMMON_CONFIG += CXXFLAGS="-g0 -O2 -ffat-lto-objects -march=$(TARGET_MARCH) -mtune=$(TUNE) $(SECURITY_FLAGS)"
COMMON_CONFIG += LDFLAGS="-s -ffat-lto-objects $(SECURITY_FLAGS_LD)"

# COMMON_CONFIG += --disable-nls
# GCC_CONFIG += --disable-libquadmath --disable-decimal-float
# GCC_CONFIG += --disable-libitm
# GCC_CONFIG += --disable-fixed-point
# GCC_CONFIG += --disable-lto
# GCC_CONFIG += --enable-languages=c,c++
# COMMON_CONFIG += --with-debug-prefix-map=$(CURDIR)=
