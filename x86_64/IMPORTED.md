# How this folder was made

These are the scripts that built `engine-x86_64-11.18-1`, as ADP Monitor's repository holds them at commit `3d5eeb55a2b9f6ef0fc0a577b9cf47b0f5cbe277`
(folder `spikes/windows-engine-intel`), with the changes below. `tools/import-build-scripts.py` in the release repository
writes this folder; the same files are the release asset `adp-engine-x86_64-11.18-1-build.tar.xz`.

Left out: `evidence/` (test logs and screenshots from the build Mac; not needed to build).

## Changed

Default paths that named folders on the build Mac now point relative to the script's own folder. Each can
still be set from the environment, and none changes what the scripts build.

- `env.sh`: default arm64 build folder (seed downloads, Hadron checkout) was a work folder of the build Mac. New text: `` $MAIN_CHECKOUT/spikes/windows-engine-arm64 ``
- `env.sh`: named the work folders of the tool that ran the build. New text: `` this folder may be in a git worktree) ``

## Added

- `BUILD-FROM-RELEASE.md`: from this release repository's `overlay/x86_64/`.
- `unpack-sources.sh`: from this release repository's `overlay/x86_64/`.
- `hadron/`: from Hadron (https://github.com/Broyojo/hadron) at `d523fe6b8fa0d8632911d49d02980769f2d4261c`: its licences, `sources.conf` (the upstream pins) and the patches this engine applied, byte for byte: wine 0013 0015 0016 0018 0021 0022 0024 0025 0027 0029 0030 0031 0032 0033 0038 0039. Hadron's Wine patches are LGPL-2.1-or-later (`hadron/patches/wine/LICENSE`, `COPYING.LIB`), its FEX patches MIT (`hadron/patches/fex/LICENSE`).
