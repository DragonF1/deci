// Deci/Audio/Permission/AudioRecordingPermission.swift
import Foundation
import AppKit
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Permission")

// MARK: - Permission Status

enum AudioCapturePermissionStatus {
    case unknown
    case authorized
    case denied
}

// MARK: - AudioRecordingPermission

@Observable
@MainActor
final class AudioRecordingPermission {

    var status: AudioCapturePermissionStatus = .unknown

    init() {
        refreshStatus()
        registerForActivation()
    }

    /// Check current TCC status without prompting.
    func refreshStatus() {
        if CGPreflightScreenCaptureAccess() {
            status = .authorized
        } else {
            status = .denied
        }
        logger.debug("Audio capture permission preflight: \(String(describing: self.status))")
    }

    /// Trigger the system permission dialog. Only shows once per app per TCC service.
    /// Subsequent calls are no-ops at the OS level.
    func request() {
        guard status != .authorized else { return }
        let granted = CGRequestScreenCaptureAccess()
        status = granted ? .authorized : .denied
        logger.info("Audio capture permission request result: \(granted)")
    }

    // MARK: - App Activation Observer

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }
}
