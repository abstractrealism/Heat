import Foundation
import SwiftUI
import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum NotificationPreference {
    /// Whether to post a notification when a response finishes. Kept in user
    /// defaults rather than the config file: it's about this machine, not
    /// about the conversations, and shouldn't travel with them.
    static let notifyOnResponse = "notifyWhenResponseCompletes"
}

/// Posts local notifications for work that finishes while you're elsewhere.
///
/// A local model can take minutes to answer, so the point is to be told when
/// it's ready rather than having to watch for it. Nothing is posted while the
/// app is frontmost — the answer is already on screen — and nothing is posted
/// unless notifications have been permitted in Settings, since asking at the
/// moment a response lands would interrupt exactly what you came back for.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: NotificationPreference.notifyOnResponse)
    }

    private var isAppActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Announces that a conversation's answer is ready.
    /// - Parameters:
    ///   - conversation: title of the conversation, for when several are running.
    ///   - preview: the opening of the answer, or nil to post the title alone.
    func responseCompleted(conversation: String, preview: String?) {
        guard isEnabled, !isAppActive else { return }
        Task { await post(title: conversation, body: preview) }
    }

    private func post(title: String, body: String?) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty {
            content.body = body
        }
        content.sound = .default

        // No trigger: deliver now.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

/// Whether the app follows the system appearance or is pinned to one.
///
/// Kept alongside the notification preference: both are about this machine
/// rather than anything in the conversations, so neither belongs in the
/// config file that travels with them.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "appAppearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil hands the decision back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
