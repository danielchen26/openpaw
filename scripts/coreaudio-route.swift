#!/usr/bin/env swift
import CoreAudio
import Foundation

struct Device: Codable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

struct Defaults: Codable {
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func dataSize(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
    var property = address(selector)
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return size
}

func deviceIDs() throws -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let size = try dataSize(system, selector: kAudioHardwarePropertyDevices)
    var ids = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    var mutableSize = size
    var property = address(kAudioHardwarePropertyDevices)
    let status = AudioObjectGetPropertyData(system, &property, 0, nil, &mutableSize, &ids)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return ids
}

func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
    var property = address(selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return value as String
}

func defaultDevice(selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var property = address(selector)
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(system, &property, 0, nil, &size, &id)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return id
}

func setDefault(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var property = address(selector)
    var mutableID = id
    let status = AudioObjectSetPropertyData(
        system,
        &property,
        0,
        nil,
        UInt32(MemoryLayout<AudioObjectID>.size),
        &mutableID
    )
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}

let devices = try deviceIDs().map {
    Device(
        id: $0,
        name: try stringProperty($0, selector: kAudioObjectPropertyName),
        uid: try stringProperty($0, selector: kAudioDevicePropertyDeviceUID)
    )
}

func device(namedOrUID value: String) throws -> Device {
    guard let device = devices.first(where: { $0.name == value || $0.uid == value }) else {
        throw NSError(
            domain: "coreaudio-route",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "audio device not found: \(value)"]
        )
    }
    return device
}

func uid(of selector: AudioObjectPropertySelector) throws -> String {
    let id = try defaultDevice(selector: selector)
    guard let device = devices.first(where: { $0.id == id }) else {
        throw NSError(
            domain: "coreaudio-route",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "default audio device \(id) was not in the device list"]
        )
    }
    return device.uid
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
switch command {
case "status":
    let defaults = Defaults(
        inputUID: try uid(of: kAudioHardwarePropertyDefaultInputDevice),
        outputUID: try uid(of: kAudioHardwarePropertyDefaultOutputDevice),
        systemOutputUID: try uid(of: kAudioHardwarePropertyDefaultSystemOutputDevice)
    )
    let data = try JSONEncoder().encode(defaults)
    print(String(decoding: data, as: UTF8.self))
case "set-all":
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "coreaudio-route", code: 4, userInfo: [NSLocalizedDescriptionKey: "set-all needs one device name or UID"])
    }
    let target = try device(namedOrUID: CommandLine.arguments[2])
    try setDefault(target.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    try setDefault(target.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    try setDefault(target.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
case "restore":
    guard CommandLine.arguments.count == 5 else {
        throw NSError(domain: "coreaudio-route", code: 5, userInfo: [NSLocalizedDescriptionKey: "restore needs input, output, and system-output UIDs"])
    }
    let requested: [(String, AudioObjectPropertySelector, String)] = [
        (CommandLine.arguments[2], kAudioHardwarePropertyDefaultInputDevice, "input"),
        (CommandLine.arguments[3], kAudioHardwarePropertyDefaultOutputDevice, "output"),
        (CommandLine.arguments[4], kAudioHardwarePropertyDefaultSystemOutputDevice, "system output"),
    ]
    var failures: [String] = []
    for (uid, selector, label) in requested {
        do {
            try setDefault(device(namedOrUID: uid).id, selector: selector)
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
        }
    }
    if !failures.isEmpty {
        fputs("could not restore every CoreAudio default:\n  \(failures.joined(separator: "\n  "))\n", stderr)
        exit(1)
    }
default:
    throw NSError(domain: "coreaudio-route", code: 6, userInfo: [NSLocalizedDescriptionKey: "unknown command: \(command)"])
}
