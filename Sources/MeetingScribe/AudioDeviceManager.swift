import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var microphonePermissionGranted = false
    @Published private(set) var screenPermissionGranted = false

    func refresh() {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        devices = session.devices
            .map {
                AudioInputDevice(
                    id: $0.uniqueID,
                    name: $0.localizedName,
                    isDefault: $0.uniqueID == defaultID
                )
            }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        microphonePermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
    }

    func preferredDeviceID(currentSelection: String?) -> String? {
        if let currentSelection, devices.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }
        return devices.first(where: \.isDefault)?.id ?? devices.first?.id
    }

    func requestMicrophonePermission() async -> Bool {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        microphonePermissionGranted = granted
        refresh()
        return granted
    }

    func requestScreenPermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        screenPermissionGranted = granted
        return granted
    }

    func markScreenCaptureAvailable() {
        screenPermissionGranted = true
    }

    func contains(deviceID: String) -> Bool {
        devices.contains { $0.id == deviceID }
    }

    func name(for deviceID: String) -> String? {
        devices.first { $0.id == deviceID }?.name
    }
}
