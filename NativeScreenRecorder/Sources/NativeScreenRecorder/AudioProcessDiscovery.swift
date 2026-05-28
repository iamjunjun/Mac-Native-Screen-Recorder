import AppKit
import CoreAudio
import Foundation
import Darwin

struct AudioProcessDiscovery {

    struct AudioProcessInfo {
        let processObjectID: AudioObjectID
        let pid: pid_t
        let name: String
        let bundleIdentifier: String
        let isRunningOutput: Bool
    }

    /// Find all audio-producing PIDs that belong to the same app as the given PID.
    /// Handles multi-process browsers (Chrome, Edge) and Safari-style XPC services.
    static func discoverAudioPIDs(forApplicationPID pid: pid_t) -> [pid_t] {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let bundleURL = runningApp?.bundleURL
        let appName = runningApp?.localizedName ?? ""
        let all = discoverRunningAudioProcesses()
        return all.compactMap { proc -> pid_t? in
            if proc.pid == pid { return pid }

            // Chrome-style: sub-processes inside the app bundle
            if let bundleURL, let procPath = executablePath(for: proc.pid),
               procPath.hasPrefix(bundleURL.path) {
                return proc.pid
            }

            // Safari-style: XPC services named after the app (e.g. "Safari Graphics and Media")
            if !appName.isEmpty, proc.name.localizedCaseInsensitiveContains(appName) {
                return proc.pid
            }

            return nil
        }
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        return pathBuf.withUnsafeBytes { raw in
            let len = raw.firstIndex(of: 0) ?? raw.count
            return String(decoding: raw[0..<len], as: UTF8.self)
        }
    }

    static func discoverRunningAudioProcesses() -> [AudioProcessInfo] {
        var result: [AudioProcessInfo] = []

        let objectIDs = readProcessObjectList()
        guard !objectIDs.isEmpty else { return result }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for objectID in objectIDs {
            guard audioObjectHasProperty(objectID, kAudioProcessPropertyPID),
                  audioObjectHasProperty(objectID, kAudioProcessPropertyIsRunningOutput),
                  let pid = readPID(objectID),
                  let isRunning = readIsRunningOutput(objectID),
                  isRunning,
                  pid > 0,
                  pid != selfPID
            else { continue }

            let (name, bundleID) = resolveProcessName(pid: pid)
            result.append(AudioProcessInfo(
                processObjectID: objectID,
                pid: pid,
                name: name,
                bundleIdentifier: bundleID,
                isRunningOutput: true
            ))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    private static func readProcessObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs
        )
        guard getStatus == noErr else { return [] }

        return objectIDs
    }

    private static func audioObjectHasProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(objectID, &address)
    }

    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = withUnsafeMutablePointer(to: &pid) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return pid
    }

    private static func readIsRunningOutput(_ objectID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &isRunning) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return isRunning != 0
    }

    private static func resolveProcessName(pid: pid_t) -> (name: String, bundleID: String) {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return (name, app.bundleIdentifier ?? "")
        }

        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            let procName = nameBuf.withUnsafeBytes { raw in
                let len = raw.firstIndex(of: 0) ?? raw.count
                return String(decoding: raw[0..<len], as: UTF8.self)
            }
            if !procName.isEmpty {
                return (procName, "")
            }
        }

        var pathBuf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
            let path = pathBuf.withUnsafeBytes { raw in
                let len = raw.firstIndex(of: 0) ?? raw.count
                return String(decoding: raw[0..<len], as: UTF8.self)
            }
            if !path.isEmpty {
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                return (fileName, "")
            }
        }

        return ("Process \(pid)", "")
    }
}
