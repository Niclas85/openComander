// Read-only discovery: no mounting, registration, or consent changes.
import Foundation
import FSKit

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let expected = "com.github.niklaus85.OpenCommander.NTFSModule"

func checkRegistrationFallback() {
    // On macOS 15.6 FSClient can omit this module even when mount -F starts
    // and activates it. Absence from that API alone is not a consent failure.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    task.arguments = ["-m", "-v", "-p", "com.apple.fskit.fsmodule", "-i", expected]
    let pipe = Pipe()
    task.standardOutput = pipe
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard task.terminationStatus == 0, output.contains(expected + "(") else {
            fail("OpenCommander NTFS is not registered. Launch the experimental app and check its File System Extension in System Settings. No image created.", code: 3)
        }
        print(output.trimmingCharacters(in: .whitespacesAndNewlines))
        print("WARNING: FSClient omitted a registered module. This does not prove it is disabled.")
        print("READY for isolated mount test; registration found, activation/write support NOT yet verified.")
        exit(0)
    } catch {
        fail("Could not inspect extension registration: \(error.localizedDescription)", code: 3)
    }
}

@available(macOS 15.4, *)
func checkExtension() {
    guard getuid() != 0 else {
        fail("Run as your login user, not with sudo: FSKit approvals are per-user.", code: 1)
    }
    FSClient.shared.fetchInstalledExtensions { modules, error in
        if let error {
            fail("FSKit discovery failed: \(error.localizedDescription)", code: 2)
        }
        for module in modules ?? [] {
            print("FSKit: \(module.bundleIdentifier) enabled=\(module.isEnabled)")
        }
        guard let module = modules?.first(where: { $0.bundleIdentifier == expected }) else {
            checkRegistrationFallback()
            return
        }
        guard module.isEnabled else {
            fail("OpenCommander NTFS is disabled. Enable its File System Extension in System Settings. No image created.", code: 4)
        }
        print("PASS FSKit extension is visible and enabled (not a mount/write test).")
        exit(0)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
    fail("FSKit discovery timed out after 10 seconds. No image created.", code: 5)
}

if #available(macOS 15.4, *) {
    checkExtension()
} else {
    fail("FSKit requires macOS 15.4 or later.", code: 1)
}
