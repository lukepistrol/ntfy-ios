import UIKit
import SafariServices
import UserNotifications
import Firebase
import FirebaseCore
import FirebaseMessaging
import CoreData

class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    private let tag = "AppDelegate"
    private let pollTopic = "~poll" // See ntfy server if ever changed
    
    // Implements navigation from notifications, see https://stackoverflow.com/a/70731861/1440785
    @Published var selectedBaseUrl: String? = nil

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Log.d(tag, "Launching AppDelegate")
        
        // Register app permissions for push notifications
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            guard success else {
                Log.e(self.tag, "Failed to register for local push notifications", error)
                return
            }
            Log.d(self.tag, "Successfully registered for local push notifications")
        }
        
        // Register too receive remote notifications
        application.registerForRemoteNotifications()

        // Set self as messaging delegate
        Messaging.messaging().delegate = self
        
        // Register to "~poll" topic
        Messaging.messaging().subscribe(toTopic: pollTopic)
        
        return true
    }
    
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.d(tag, "Background notification received", userInfo)
        
        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            completionHandler(.noData)
            return
        }

        // Poll and show new messages as notifications
        let store = Store.shared
        let subscriptionManager = SubscriptionManager(store: store)
        store.getSubscriptions()?.forEach { subscription in
            subscriptionManager.poll(subscription) { messages in
                messages.forEach { message in
                    self.showNotification(subscription, message)
                }
            }
        }
        completionHandler(.newData)
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data in String(format: "%02.2hhx", data) }.joined()
        Messaging.messaging().apnsToken = deviceToken
        Log.d(tag, "Registered for remote notifications. Passing APNs token to Firebase: \(token)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.e(tag, "Failed to register for remote notifications", error)
    }
    
    /// Create a local notification manually (as opposed to a remote notification being generated by Firebase). We need to make the
    /// local notification look exactly like the remote one (same userInfo), so that when we tap it, the userNotificationCenter(didReceive) function
    /// has the same information available.
    private func showNotification(_ subscription: Subscription, _ message: Message) {
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: subscription.baseUrl ?? "?")
    
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil /* now */)
        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                Log.e(self.tag, "Unable to create notification", error)
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. Nothing has to be done here, except call the completionHandler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
        completionHandler([[.banner, .sound]])
    }
    
    /// Executed when the user clicks on the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(didReceive)", userInfo)
        guard let message = Message.from(userInfo: userInfo) else {
            Log.w(tag, "Cannot convert userInfo to message", userInfo)
            completionHandler()
            return
        }
        
        let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        let action = message.actions?.first { $0.id == response.actionIdentifier }

        // Show current topic
        if message.topic != "" {
            selectedBaseUrl = topicUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Execute user action or click action (if any)
        if let action = action {
            ActionExecutor.execute(action)
        } else if let click = message.click, click != "", let url = URL(string: click) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    
        completionHandler()
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Log.d(tag, "Firebase token received: \(String(describing: fcmToken))")
        
        // We don't actually need the FCM token, since we're just using topics.
        // We still print it so we can see if things were successful.
    }
}
