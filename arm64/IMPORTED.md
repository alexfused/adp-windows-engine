# How this folder was made

These are the scripts that built `engine-arm64-11.18-2`, as ADP Monitor's repository holds them at commit `0da76e722f0b9775ddd4ffe37f7e5605eca5b977`
(folder `spikes/windows-engine-arm64`), with the changes below. `tools/import-build-scripts.py` in the release repository
writes this folder; the same files are the release asset `adp-engine-arm64-11.18-2-build.tar.xz`.

Left out: `evidence/` (test logs and screenshots from the build Mac; not needed to build).

## Changed

Default paths that named folders on the build Mac now point relative to the script's own folder. Each can
still be set from the environment, and none changes what the scripts build.

- `SOURCES.md`: the test programs' folder was named by its place on the build Mac. New text: `` (`spikes/windows-apps/downloads` in ADP Monitor) ``
- `env.sh`: default provisioning profile: now relative to the ADP Monitor checkout. New text: `` PROFILE="${ADP_PROFILE:-$SPIKE/../../dist/profiles/ADP_Monitor_Windows_Engine_Developer_ID.provisionprofile}" ``
- `fetch.sh`: default folder of earlier verified downloads: now relative to the ADP Monitor checkout. New text: `` seed="${ADP_EXT_SEED:-$SPIKE/../windows-engine-release/downloads/fetch}" ``
- `helper-check.sh`: the second control (the withdrawn 11.18-1 loader) was named by its place on the build Mac. New text: `` "${ADP_OLD_WINEHOST:-$DIST/stage/engine-arm64-11.18-1/lib/wine/aarch64-unix/WineHost.app}" ``
- `programs.sh`: default folder of the test programs: now relative to the ADP Monitor checkout. New text: `` from="${1:-$SPIKE/../windows-apps/downloads}" ``
- `RESULTS.md`: named the build Mac's home folder. New text: `` `/var/folders` or the build Mac's home folder anywhere ``

## Added

- `BUILD-FROM-RELEASE.md`: from this release repository's `overlay/arm64/`.
- `unpack-sources.sh`: from this release repository's `overlay/arm64/`.
- `hadron/`: from Hadron (https://github.com/Broyojo/hadron) at `d523fe6b8fa0d8632911d49d02980769f2d4261c`: its licences, `sources.conf` (the upstream pins) and the patches this engine applied, byte for byte: wine 0001 0002 0003 0004 0005 0006 0008 0010 0011 0013 0015 0016 0018 0019 0020 0021 0022 0024 0025 0027 0029 0030 0031 0032 0033 0034 0035 0036 0038 0039; fex 0001 0002 0003 0004 0005. Hadron's Wine patches are LGPL-2.1-or-later (`hadron/patches/wine/LICENSE`, `COPYING.LIB`), its FEX patches MIT (`hadron/patches/fex/LICENSE`).
