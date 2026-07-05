import AppKit
import Foundation
import UserNotifications

enum NotificationPermissionState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let meetingIDKey = "meetingID"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func permissionState() async -> NotificationPermissionState {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined:
                    continuation.resume(returning: .notDetermined)
                case .denied:
                    continuation.resume(returning: .denied)
                case .authorized, .provisional, .ephemeral:
                    continuation.resume(returning: .authorized)
                @unknown default:
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    func requestPermission() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func notifyTranscriptionFinished(for record: MeetingRecord, succeeded: Bool) async {
        guard await permissionState() == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Transcrição pronta" : "Transcrição não concluída"
        content.body = succeeded
            ? "\(record.title): o WAV e a transcrição estão disponíveis."
            : "\(record.title): o WAV foi salvo e você pode refazer a transcrição."
        content.sound = .default
        content.userInfo = [Self.meetingIDKey: record.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "transcricao-\(record.id.uuidString)-\(succeeded ? "pronta" : "falha")",
            content: content,
            trigger: nil
        )
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                center.add(request) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            NSLog("Não foi possível enviar a notificação: %@", error.localizedDescription)
        }
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let rawID = response.notification.request.content.userInfo[Self.meetingIDKey] as? String,
              let id = UUID(uuidString: rawID) else { return }
        let url = MeetingRoute.url(for: id)
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
