Two Windows engines for ADP Monitor, both built from source by ADP Monitor's scripts. Each engine has a manifest (`*.manifest.json`: download URL, SHA-256, size, layout, health check, signing, and every source file) and a licence file (`*.THIRD-PARTY-LICENSES.md`). The other files are the corresponding source.

| Engine | For | Archive | SHA-256 |
|---|---|---|---|
| `engine-arm64-11.18-2` | Apple silicon, macOS 27 or later, no Rosetta | `engine-arm64-11.18-2.tar.xz` | `67cb8cde7299c701a3aae047ba13ae7fff69237904e383eae8536d1f8e8e1c94` |
| `engine-x86_64-11.18-1` | Intel Macs, macOS 12.3 or later | `engine-x86_64-11.18-1.tar.xz` | `bb512d1e1433926305707bed0ff24a10c481fc3d1a217abdee7a296f09788e87` |

Both are Wine 11.18 (a development snapshot, upstream commit 6880117619af) with some of Hadron's Wine patches (d523fe6b8fa0), and GnuTLS, Nettle, GMP, libtasn1 and FreeType built from their release tarballs into `lib/ext`.

**`engine-arm64-11.18-2`** adds FEX 0df84d3844bc with Hadron's 5 FEX patches, so x86 and x86-64 Windows programs run on Apple silicon without Rosetta. Signed with Alex Parkin's Developer ID under the engine's own identifier `com.alexparkin.adpmonitor.winehost` and notarised by Apple.

**`engine-x86_64-11.18-1`** runs x86 and x86-64 Windows programs natively on Intel Macs (macOS 12.3 or later). It was cross-compiled on Apple silicon. Its first test run, on an Intel iMac with macOS 26.7.1, passed 9 of the 10 required checks. The tenth failed because of a timing bug in the test script, since fixed. A full rerun is still to come. It is signed under the same identifier. Apple notarised it on 22 October 2026, after this release was published (submission 9d595ff6-8168-4498-a284-1663f99781f8). The archive did not change. It has no app to staple the ticket to, so Gatekeeper fetches the ticket from Apple. The engine's manifest was written before notarisation and still says `"notarized": false`.

Check a download: `shasum -a 256 -c SHA256SUMS --ignore-missing`.

Licences: Wine is LGPL-2.1-or-later; the other components and their licences are listed in THIRD-PARTY-LICENSES.md and in each engine's licence file. This repository's own scripts are MIT.
