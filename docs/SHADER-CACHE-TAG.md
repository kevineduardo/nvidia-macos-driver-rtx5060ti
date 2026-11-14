# The shader cache's build tag, and the black screen it caused

## What happened (2026-11-14, RTX 5060 Ti, macOS 26.7.2, 3.0)

`libnvencvt.dylib` was replaced inside `/Library/GPUBundles/NVMTLDriver.bundle` and the bundle was sealed again with
`codesign --force --deep`. That signed every library in the bundle again, the shader translator
(`libnvmtl_translate.dylib`) among them: the same code, another file (`2fd53e2a…` → `4734dbfa…`).

The plugin named every shader-cache entry after the SHA-256 of that whole file. With another digest every process took
its cache for another translator build's and swept it. Nothing showed until the restart:

| time | |
|---|---|
| 15:24:11 | boot |
| 15:24:31 | WindowServer initialised; 15:24:33 the login window waits for authentication |
| ~15:24:38 | WindowServer's main thread enters the plugin from QuartzCore and waits (a dispatch semaphore) on translations running on `nvmtl.fc-warm` at utility priority, two at a time |
| 15:25:36 | watchdogd: "WindowServer main thread … 40 seconds since last successful checkin" - WindowServer is killed (`WindowServer-…​.ips`, bug type 409, and a `.spin`), loginwindow exits |
| ~15:26:05 | the second WindowServer is up; its cache now holds 450 entries |

Two minutes of black screen and no Apple logo. The reports are in `/Library/Logs/DiagnosticReports`; the main thread's
stack in the `.spin` ends in `NVMTLDriver` under QuartzCore, and the note "too many dispatch threads blocked in synchronous
operations" is the warm-up queue.

## What changed

- **The tag** (`plugin/nvmtl_translator_tag.h`) is a digest of the translator's `LC_UUID` and of every segment except
  `__LINKEDIT`, without the Mach-O header, the load commands and the padding after them. Signing does not touch any of
  that: the 3.0 translator as packaged, signed again (with any identifier) and unsigned all give `sha256-8d0a4d16…`.
  `tools/test_translator_tag.py` proves it on a sample dylib, with the old tag as the control.
- **Installing one file into the bundle**: `tools/install_bundle_file.sh <file> <name>` signs only that file, seals
  without `--deep`, and stops if anything else in the bundle changed. Do not use `--deep` on the installed bundle.
- **Building the plugin here**: `build/build_plugin_release_local.sh <rev> <out>`. It reproduces the shipped binary (the
  same `LC_UUID` for an unchanged commit), so a difference in a build of yours is your change.

## Keeping the caches across the change

The new scheme is itself one more new tag, and would have cost one more cold start. An entry carries the tag only in its
name, so `tools/migrate_shader_cache_tag.sh <old tag> <new tag>` hard-links every entry of the old tag under the new one
(2,384 entries in 40 folders here: WindowServer's 450, the login window's 557, the user's and the app containers').
`tools/translator_tag.c` prints both tags of a translator. Order:

```sh
clang -O1 -I plugin -o /tmp/translator_tag tools/translator_tag.c
/tmp/translator_tag /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvmtl_translate.dylib   # new … old …
sudo tools/migrate_shader_cache_tag.sh --store /Library/NullMoth/shader-cache-migration <old> <new>
tools/install_bundle_file.sh <out>/NVMTLDriver NVMTLDriver
sudo tools/migrate_shader_cache_tag.sh --relink --store /Library/NullMoth/shader-cache-migration     # again just before the restart
```

A process still running the old plugin sweeps the new names from the folders it uses when it first touches its cache;
`--relink` puts them back from the store. Proof that the new plugin reads the migrated entries: a program that compiles a
Metal library and builds two pipelines logged 2 misses, then 2 hits, on the old plugin, and 2 hits and 0 misses on the
new one with the new tag (`NVMTL_PROCESS_ENV=1 NVMTL_LOG_PATH=…`, lines "fc cache: HIT" / "refl cache: HIT").

## Still open

A cold cache still stalls WindowServer after a real translator update (the plugin's own notes measured 107 s with
nothing on screen). The main thread waits on a group whose work is queued at utility priority behind every other
recorded variant, two at a time (`nvmtl_fcwarm_kick`); letting the variant the main thread waits for go first, or
raising the queue while someone waits, would keep that start under the watchdog's 40 seconds.

---
Copyright (c) 2026 kevineduardo. Licensed under the MIT License (SPDX-License-Identifier: MIT).
