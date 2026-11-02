import Foundation
import Observation
import UIKit
import UserNotifications
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics
import FirebaseMessaging
import FirebaseRemoteConfig

@MainActor @Observable final class CloudServices {
    static let shared = CloudServices()
    private(set) var available = false
    private(set) var refreshing = false
    private(set) var update: AppUpdate?
    private(set) var notificationStatus = UNAuthorizationStatus.notDetermined
    var registrationReady = false
    @ObservationIgnored private var config: RemoteConfig?
    @ObservationIgnored private var listener: ConfigUpdateListenerRegistration?
    private var staging: Bool { Bundle.main.object(forInfoDictionaryKey: "KoharuEnvironment") as? String == "staging" }

    func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        // Preview the blocking screen without publishing a policy or sending telemetry.
        if ProcessInfo.processInfo.arguments.contains("-KoharuPreviewRequiredUpdate") {
            update = AppUpdate(version: "2.0.0", storeURL: URL(string: "https://apps.apple.com")!)
            return
        }
        #endif
        guard !available, let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path), options.bundleID == Bundle.main.bundleIdentifier else { return }
        FirebaseApp.configure(options: options)
        available = true
        Analytics.setAnalyticsCollectionEnabled(true)
        #if DEBUG
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        #else
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        #endif
        let remote = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = staging ? 60 : 3600
        settings.fetchTimeout = 10
        remote.configSettings = settings
        remote.setDefaults(fromPlist: "RemoteConfigDefaults")
        config = remote
        applyUpdates()
        listener = remote.addOnConfigUpdateListener { [weak self] _, error in
            guard error == nil else { return }
            Task { @MainActor in
                guard let self, let config = self.config else { return }
                do { _ = try await config.activate(); self.applyUpdates() } catch { }
            }
        }
    }

    func refreshUpdates(force: Bool = false) async {
        guard let config, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // SDK persistence keeps the last activated policy across offline launches.
        do {
            if force {
                _ = try await config.fetch(withExpirationDuration: 0)
                _ = try await config.activate()
            } else { _ = try await config.fetchAndActivate() }
            applyUpdates()
        } catch { }
    }

    private func applyUpdates() {
        guard let config else { return }
        update = AppUpdate.required(
            current: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            minimum: config["game_version"].stringValue,
            enabled: config["force_update_enabled"].boolValue,
            store: config["apple_store_url"].stringValue,
            allowTestFlight: staging)
    }

    func trackScreen(_ name: String) {
        guard available else { return }
        // Screen names only; manga text, URLs, prompts and credentials never enter telemetry.
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: name])
    }

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if available && [.authorized, .provisional, .ephemeral].contains(notificationStatus) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func requestNotifications() async {
        guard available else { return }
        await refreshNotificationStatus()
        if notificationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshNotificationStatus()
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            _ = await UIApplication.shared.open(url)
        }
    }

    var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return registrationReady ? L("On") : L("Connecting…")
        case .denied: return L("Off")
        default: return L("Not requested")
        }
    }
}

final class CloudAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CloudServices.shared.configure()
        guard CloudServices.shared.available else { return true }
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        Task { await CloudServices.shared.refreshNotificationStatus() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistration installationId: String?) {
        Task { @MainActor in CloudServices.shared.registrationReady = installationId != nil }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Messaging.messaging().appDidReceiveMessage(notification.request.content.userInfo)
        return [.banner, .badge, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        Messaging.messaging().appDidReceiveMessage(response.notification.request.content.userInfo)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
        completionHandler(.noData)
    }
}
