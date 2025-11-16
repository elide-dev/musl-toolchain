
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
