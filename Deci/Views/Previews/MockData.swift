// FineTune/Views/Previews/MockData.swift
import AppKit
import AudioToolbox

/// Mock data for SwiftUI previews
enum MockData {

    // MARK: - Sample Apps

    static let sampleApps: [AudioApp] = [
        AudioApp(
            id: 1001,
            processObjectIDs: [AudioObjectID(1001)],
            name: "Spotify",
            icon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.spotify.client"
        ),
        AudioApp(
            id: 1002,
            processObjectIDs: [AudioObjectID(1002)],
            name: "Chrome",
            icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.google.Chrome"
        ),
        AudioApp(
            id: 1003,
            processObjectIDs: [AudioObjectID(1003)],
            name: "Zoom",
            icon: NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "us.zoom.xos"
        ),
        AudioApp(
            id: 1004,
            processObjectIDs: [AudioObjectID(1004)],
            name: "Discord",
            icon: NSImage(systemSymbolName: "message", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.hnc.Discord"
        ),
        AudioApp(
            id: 1005,
            processObjectIDs: [AudioObjectID(1005)],
            name: "Music",
            icon: NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.apple.Music"
        )
    ]

    // MARK: - Sample Devices

    static let sampleDevices: [AudioDevice] = [
        AudioDevice(
            id: AudioDeviceID(100),
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Pro Speakers",
            icon: NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil),
            supportsAutoEQ: false
        ),
        AudioDevice(
            id: AudioDeviceID(101),
            uid: "AirPodsProDevice",
            name: "AirPods Pro",
            icon: NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil),
            supportsAutoEQ: true
        ),
        AudioDevice(
            id: AudioDeviceID(102),
            uid: "HDMIDisplayDevice",
            name: "LG UltraFine Display",
            icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil),
            supportsAutoEQ: false
        ),
        AudioDevice(
            id: AudioDeviceID(103),
            uid: "HomePodDevice",
            name: "Living Room HomePod",
            icon: NSImage(systemSymbolName: "homepod", accessibilityDescription: nil),
            supportsAutoEQ: false
        )
    ]

    // MARK: - Sample Paired Bluetooth Devices

    static let samplePairedDevices: [PairedBluetoothDevice] = [
        PairedBluetoothDevice(
            id: "AA:BB:CC:DD:EE:FF",
            name: "Sony WH-1000XM5",
            icon: NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        ),
        PairedBluetoothDevice(
            id: "11:22:33:44:55:66",
            name: "AirPods Pro",
            icon: NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil)
        ),
    ]
}
