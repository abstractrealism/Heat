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

    @State private var hasNotificationPermission = false
    @State private var hasLocationPermission = false        // NSLocationWhenInUseUsageDescription
    @State private var hasMusicPermission = false           // NSAppleMusicUsageDescription

    init(_ permission: Permission) {
        self.permission = permission
    }

    var body: some View {
        Form {
            switch permission {
            case .notifications:
                Toggle("Notifications", isOn: Binding(
                    get: { hasNotificationPermission },
                    set: { shouldGetPermission in
                        if shouldGetPermission && !hasNotificationPermission {
                            requestNotificationPermission()
                        }
                    }
                ))

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
        .onAppear {
            getNotificationSettings()
            getLocationSettings()
            getMusicSettings()
        }
        .onChange(of: locationManager.authorizationStatus) { _, newValue in
            getLocationSettings()
        }
    }

    // Notifications

    @State private var locationManager = LocationManager()

    func getNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined, .denied:
                hasNotificationPermission = false
            case .authorized, .provisional, .ephemeral:
                hasNotificationPermission = true
            @unknown default:
                hasNotificationPermission = false
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            hasNotificationPermission = granted
        }
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
