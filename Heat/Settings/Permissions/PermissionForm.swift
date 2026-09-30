import SwiftUI
import HeatKit

import UserNotifications
import EventKit
import CoreLocation
import MusicKit

struct PermissionForm: View {
    @Environment(AppState.self) var state

    let permission: Permission

    @AppStorage(NotificationPreference.notifyOnResponse) private var notifyOnResponse = false

    /// What the system says, kept rather than reduced to a yes or no: the
    /// three cases want three different things offered, and only one of them
    /// is a toggle this app can act on.
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    @State private var hasLocationPermission = false        // NSLocationWhenInUseUsageDescription
    @State private var hasMusicPermission = false           // NSAppleMusicUsageDescription

    @Environment(\.scenePhase) private var scenePhase

    private var hasNotificationPermission: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    init(_ permission: Permission) {
        self.permission = permission
    }

    var body: some View {
        Form {
            switch permission {
            case .notifications:
                // Only askable once. After that the answer lives in System
                // Settings and this can report it, not change it — so the
                // toggle is disabled rather than pretending, and where it is
                // off for good there is a way through to the place that can.
                Toggle("Notifications", isOn: Binding(
                    get: { hasNotificationPermission },
                    set: { wanted in
                        guard wanted, notificationStatus == .notDetermined else { return }
                        Task { await requestNotificationPermission() }
                    }
                ))
                .disabled(notificationStatus != .notDetermined)

                if notificationStatus == .denied {
                    Text("Turned off for Heat in System Settings, so nothing can be sent.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Link("Open Notification Settings", destination: Self.systemNotificationSettings)
                        .font(.footnote)
                }

                Toggle("Notify when a response finishes", isOn: $notifyOnResponse)
                    .disabled(!hasNotificationPermission)
                Text("Sends only when Heat isn't the active app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .location:
                Toggle("Location", isOn: Binding(get: { hasLocationPermission }, set: { shouldGetPermission in
                    if shouldGetPermission && !hasLocationPermission {
                        requestLocationPermission()
                    }
                }))
                Text("Nothing uses this yet — no tool asks for your location. Granting it changes nothing today. To tell the assistant where you are, put it in Location under General.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .music:
                Toggle("Music", isOn: Binding(get: { hasMusicPermission }, set: { shouldGetPermission in
                    if shouldGetPermission && !hasMusicPermission {
                        requestMusicPermission()
                    }
                }))
                Text("Nothing uses this yet — there's no music tool. Granting it changes nothing today.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadNotificationSettings() }
        // Because the answer can be changed in System Settings while this is
        // open — including by the link above, which sends you there to do it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await loadNotificationSettings() }
        }
        .onAppear {
            getLocationSettings()
            getMusicSettings()
        }
        .onChange(of: locationManager.authorizationStatus) { _, newValue in
            getLocationSettings()
        }
    }

    // Notifications

    @State private var locationManager = LocationManager()

    /// Where System Settings keeps the answer, for the case this can't change.
    private static let systemNotificationSettings: URL = {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #else
        URL(string: UIApplication.openSettingsURLString)!
        #endif
    }()

    /// Awaited rather than given a completion handler, which is what was
    /// wrong here.
    ///
    /// `getNotificationSettings(completionHandler:)` calls back on a queue of
    /// its own, and the handler assigned straight to `@State` from there.
    /// SwiftUI never saw the write, so the Notifications toggle read false
    /// however the permission actually stood — and because the second toggle
    /// is disabled on that same value, the pane showed an unchecked parent
    /// above a checked, greyed-out child, while notifications went on being
    /// delivered. They were delivered because `NotificationManager` asks the
    /// system itself at send time and never consulted this at all; only the
    /// display was ever wrong.
    ///
    /// The `await` resumes on the main actor, where a view's state belongs.
    private func loadNotificationSettings() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        // Read back rather than trusting what the request returned: a denial
        // and a dismissal answer the same way, and the status distinguishes
        // them.
        await loadNotificationSettings()
    }

    // Location

    func getLocationSettings() {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .restricted, .authorized, .authorizedWhenInUse:
            hasLocationPermission = true
        case .notDetermined, .denied:
            hasLocationPermission = false
        @unknown default:
            hasLocationPermission = false
        }
    }

    func requestLocationPermission() {
        locationManager.requestAuthorization()
    }

    // Music

    func getMusicSettings() {
        switch MusicAuthorization.currentStatus {
        case .notDetermined, .denied, .restricted:
            hasMusicPermission = false
        case .authorized:
            hasMusicPermission = true
        @unknown default:
            hasMusicPermission = false
        }
    }

    func requestMusicPermission() {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            hasMusicPermission = true
        default:
            Task {
                let status = await MusicAuthorization.request()
                switch status {
                case .notDetermined, .denied, .restricted:
                    hasMusicPermission = false
                case .authorized:
                    hasMusicPermission = true
                @unknown default:
                    hasMusicPermission = false
                }
            }
        }
    }
}
