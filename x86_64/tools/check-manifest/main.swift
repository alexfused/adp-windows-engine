// SPDX-License-Identifier: MIT
// Checks an engine manifest with ADP Monitor's own code: verify.sh compiles this file together with
// Sources/FleetCore/WindowsApps/WindowsEngine.swift (and the two FleetCore files it needs) and runs
// it natively (arm64). It only reads files.
//
//   check-manifest <app-manifest.json> [<folder the archive was unpacked into>]
//
// 1. decodes the JSON as WindowsEngineManifest with the app's decoder settings (FleetMessage.decoder)
// 2. isValid(): https URLs, a real SHA-256, a folder-safe version, paths that stay inside the engine
// 3. WindowsEngineCatalog.choose picks it for Intel Macs and refuses it for Apple chips
// 4. with an unpacked archive: archiveRoot is a folder, wine and wineserver exist and are executable,
//    and MachOArchs.read (the app's no-Rosetta check) says every nativeBinaries file is x86_64 only
import Foundation

func fail(_ s: String) -> Never { print("FAIL: \(s)"); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: check-manifest <manifest.json> [unpacked-dir]"); exit(2) }
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
let data: Data
do { data = try Data(contentsOf: URL(fileURLWithPath: args[1])) } catch { fail("cannot read \(args[1]): \(error)") }
let m: WindowsEngineManifest
do { m = try decoder.decode(WindowsEngineManifest.self, from: data) } catch { fail("does not decode as WindowsEngineManifest: \(error)") }
print("decoded: version \(m.version), arch \(m.arch.rawValue), \(m.bytes) bytes, sha256 \(m.sha256)")
print("decoded: archiveRoot \(m.archiveRoot), wine \(m.wine), wineserver \(m.wineserver), nativeBinaries \(m.nativeBinaries)")
guard m.isValid() else { fail("isValid() is false") }
print("isValid: true")
guard m.arch == .x86_64 else { fail("arch is \(m.arch.rawValue), not x86_64") }
if case .available(let chosen) = WindowsEngineCatalog.choose(for: .x86_64, from: [m]), chosen == m {
    print("choose(for: x86_64): available")
} else { fail("the catalog does not choose it for Intel Macs") }
if case .unavailable(let why) = WindowsEngineCatalog.choose(for: .arm64, from: [m]) {
    print("choose(for: arm64): unavailable (\"\(why)\"), so it is never offered to an Apple chip")
} else { fail("the catalog would offer an x86_64 engine to an Apple chip") }

if args.count >= 3 {
    let kept = args[2] + "/" + m.archiveRoot
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: kept, isDirectory: &isDir), isDir.boolValue else { fail("no folder \(m.archiveRoot) in the archive") }
    for rel in [m.wine, m.wineserver] where !FileManager.default.isExecutableFile(atPath: kept + "/" + rel) {
        fail("\(rel) is not an executable file")
    }
    for rel in m.nativeBinaries {
        guard let h = FileHandle(forReadingAtPath: kept + "/" + rel) else { fail("missing \(rel)") }
        let header = h.readData(ofLength: 4096); try? h.close()
        guard let archs = MachOArchs.read(header) else { fail("\(rel) is not a Mach-O file") }
        guard archs == [.x86_64] else { fail("\(rel) is built for \(archs.map(\.rawValue).sorted()), not x86_64 only") }
        print("MachOArchs.read(\(rel)): [x86_64]")
    }
}
print("PASS")
