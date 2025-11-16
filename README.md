
## musl toolchain

This project prepares a libc musl toolchain from scratch, for use with Elide and general Native Image projects which target `linux-amd64`. Prepackaged are the following libraries, all built from sources, with consistent `CFLAGS` and compat with musl:

- [`mimalloc`](https://github.com/microsoft/mimalloc), which is built with stage1 musl gcc, then injected at stage2
- [`musl`](https://github.com/elide-tools/musl), built with latest patches and then injected with mimalloc
- [`zlib`](https://github.com/cloudflare/zlib), cloudflare's optimized fork
- [`openssl`](https://github.com/openssl/openssl), with optimizations turned on
- [`sqlite`](https://github.com/sqlite/sqlite), latest version, properly built for musl, optimizations on

### Usage

1) Build.

```
./build.sh
# ...
-----------------------------------------------
Musl Sysroot (1.2.5-patched.2):
  Location: /.../musl/1.2.5
  Compiler: /.../musl/1.2.5/bin/musl-gcc
  Arch:     x86-64-v4
  Tune:     znver3

Compiler flags:
  CFLAGS:   -I/.../musl/1.2.5/include
  LDFLAGS:  -L/.../musl/1.2.5/lib -static
  CC:       /.../musl/1.2.5/bin/musl-gcc
  CFLAGS:   -march=x86-64-v4 -mtune=znver3 -O2 -ffat-lto-objects -fstack-protector-strong -Wl,-z,relro,-z,now -Wa,--noexecstack -D_FORTIFY_SOURCE=2 -I/.../musl/1.2.5/include -I/usr/include/x86_64-linux-musl -flto=auto -fPIE -fPIC
  LDFLAGS:  -ffat-lto-objects -L/.../musl/1.2.5/lib -flto=auto -static -Wl,-z,relro,-z,now,-z,noexecstack

Components:
  mimalloc:   3.1.5
  libc:       /.../musl/1.2.5/lib/libc.a: current ar archive
  zlib:       (cloudflare@gcc.amd64) /.../musl/1.2.5/lib/libz.a: current ar archive
  openssl:    3.6.0 /.../musl/1.2.5/lib64/libssl.a: current ar archive
  sqlite:     3.51.0 /.../musl/1.2.5/lib/libsqlite3.a: current ar archive

Features:
  Secure:         OFF
  Guarded:        OFF
  CFI:            no
  Mimalloc:       yes
  Musl+Mimalloc:  yes
-----------------------------------------------
```

2) Set variables and run build.

```
export CC=$PWD/latest/x86_64-linux-musl-gcc
// ... or ...
./configure --prefix=$PWD/latest
```

3) ????

4) PROFIT!

```
> env MIMALLOC_SHOW_STATS=1 ./.dev/artifacts/native/elide/elide --version

2.0.0-alpha.1
heap stats:     peak       total     current       block      total#
  reserved:     1.0 GiB     1.0 GiB     1.0 GiB
 committed:     2.5 MiB     2.6 MiB     2.3 MiB
     reset:     0
    purged:   257.0 KiB
   touched:     0           0           0                                ok
     pages:     4           4           0                                ok
-abandoned:     0           0           0                                ok
 -reclaima:     0
 -reclaimf:     0
-reabandon:     0
    -waits:     0
 -extended:     0
   -retire:     0
    arenas:     1
 -rollback:     0
     mmaps:     3
   commits:     4
    resets:     0
    purges:     1
   guarded:     0
   threads:     0           0           0                                ok
  searches:     0.0 avg
numa nodes:     1
   elapsed:     0.000 s
   process: user: 0.000 s, system: 0.000 s, faults: 0, rss: 6.0 MiB, commit: 2.5 Mi
```

### Modifications / Settings

The prepared sysroot includes all libraries, built statically, with the bootstrapped compiler. Modifications to Musl and libraries are listed below:

- **Musl Libc**
  - Patches ([1](./musl/patches/patch-1.patch), [2](./musl/patches/patch-2.patch)) applied according to upstream advice
  - Patch ([3](./musl/patches/patch-3-elide-1.patch)) applied to swap `memallocng` for `mimalloc`, default to `-O2`
  - Musl is built with `-O3` for subsystems `internal,malloc,string`
- **Mimalloc**
  - Built in secure mode by default
  - Built with bootstrapped musl compiler, then used for stage2 build
- **Zlib**
  - Uses Cloudflare's accelerated fork of [zlib](https://github.com/cloudflare/zlib)
- **OpenSSL**
  - Builds with curve optimizations enabled, TLSv1.3 support

`CFLAGS` underwent a round of hardening and optimization. Barring build conflicts, the following settings are applied to all compiled code:

```
-O2
-flto=auto
-ffat-lto-objects
-fno-plt
-fstack-protector-strong
-fomit-frame-pointer
-Wl,-z,relro,-z,now -Wa,--noexecstack

-march=x86-64-v4             # amd64
-mtune=znver3                # amd64
-march=armv8.4-a+crypto+sve  # arm64
-mtune=neoverse-v1           # arm64
```
