import AppKit
import Foundation

class SlackPresenceMonitor: ObservableObject {

    // MARK: - Constants

    private enum Keys {
        static let slackCookie = "slackCookie"
        static let slackToken = "slackToken"
        static let slackCoworkers = "slackCoworkers"
        static let slackEnabled = "slackEnabled"
        static let slackRequireApp = "slackRequireApp"
        static let showMeetingStatus = "slackShowMeetingStatus"
    }

    private enum Defaults {
        static let reconnectInterval: TimeInterval = 540  // 9 minutes
    }

    // MARK: - Singleton

    static let shared = SlackPresenceMonitor()

    // MARK: - Published Properties

    @Published private(set) var onlineInitials: String = ""
    @Published private(set) var isMeActive: Bool = false

    // MARK: - Properties

    var cookie: String {
        didSet { UserDefaults.standard.set(cookie, forKey: Keys.slackCookie) }
    }

    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Keys.slackToken) }
    }

    /// Dictionary mapping Slack user ID to first name
    var coworkers: [String: String] {
        didSet { UserDefaults.standard.set(coworkers, forKey: Keys.slackCoworkers) }
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.slackEnabled)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    var requireSlackApp: Bool {
        didSet {
            UserDefaults.standard.set(requireSlackApp, forKey: Keys.slackRequireApp)
            if isEnabled {
                if requireSlackApp {
                    // Starting to require Slack app - set up monitoring
                    startSlackAppMonitoring()
                } else {
                    // No longer requiring Slack app - stop monitoring and connect
                    slackAppCheckTimer?.invalidate()
                    slackAppCheckTimer = nil
                    if !isConnected {
                        connect()
                    }
                }
            }
        }
    }

    var showMeetingStatus: Bool {
        didSet {
            UserDefaults.standard.set(showMeetingStatus, forKey: Keys.showMeetingStatus)
            updateInitials()
        }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnectTimer: Timer?
    private var slackAppCheckTimer: Timer?
    private var onlineUsers: Set<String> = []
    private var usersInMeeting: Set<String> = []
    private var messageId: Int = 1
    private var isConnected: Bool = false

    /// Emojis that indicate the user is in a meeting or huddle
    private let meetingEmojis = [":calendar:", ":spiral_calendar_pad:", ":date:", ":headphones:"]

    // MARK: - Initialization

    private init() {
        cookie = UserDefaults.standard.string(forKey: Keys.slackCookie) ?? ""
        token = UserDefaults.standard.string(forKey: Keys.slackToken) ?? ""
        coworkers =
            UserDefaults.standard.dictionary(forKey: Keys.slackCoworkers) as? [String: String]
            ?? [:]
        isEnabled = UserDefaults.standard.bool(forKey: Keys.slackEnabled)
        // Default to requiring Slack app to be open
        if UserDefaults.standard.object(forKey: Keys.slackRequireApp) == nil {
            requireSlackApp = true
        } else {
            requireSlackApp = UserDefaults.standard.bool(forKey: Keys.slackRequireApp)
        }
        // Default to showing meeting status
        if UserDefaults.standard.object(forKey: Keys.showMeetingStatus) == nil {
            showMeetingStatus = true
        } else {
            showMeetingStatus = UserDefaults.standard.bool(forKey: Keys.showMeetingStatus)
        }
        session = URLSession(configuration: .default)
        setupWakeObserver()
    }

    private func setupWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }
            print("Mac woke from sleep, reconnecting Slack WebSocket...")
            // Brief delay to let network come back up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.reconnect()
            }
        }
    }

    // MARK: - Public Methods

    func start() {
        guard isEnabled else {
            print("Slack presence monitoring is disabled")
            return
        }
        guard !cookie.isEmpty, !token.isEmpty, !coworkers.isEmpty else {
            print("Slack credentials or coworkers not configured")
            return
        }
        if requireSlackApp {
            startSlackAppMonitoring()
        } else {
            connect()
        }
    }

    private func startSlackAppMonitoring() {
        // Check immediately
        checkSlackAppState()

        // Then check periodically
        slackAppCheckTimer?.invalidate()
        slackAppCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
            [weak self] _ in
            self?.checkSlackAppState()
        }
        if let timer = slackAppCheckTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func checkSlackAppState() {
        let slackIsRunning = isSlackRunning()

        if slackIsRunning && !isConnected {
            print("Slack app detected, connecting WebSocket...")
            connect()
        } else if !slackIsRunning && isConnected {
            print("Slack app closed, disconnecting WebSocket...")
            disconnect()
        }
    }

    private func isSlackRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.tinyspeck.slackmacgap"
        }
    }

    private func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        onlineUsers.removeAll()
        usersInMeeting.removeAll()
        updateInitials()
    }

    func stop() {
        slackAppCheckTimer?.invalidate()
        slackAppCheckTimer = nil
        disconnect()
    }

    func reconnect() {
        disconnect()
        if isEnabled {
            if requireSlackApp {
                if isSlackRunning() {
                    connect()
                }
            } else {
                connect()
            }
        }
    }

    var isConfigured: Bool {
        !cookie.isEmpty && !token.isEmpty && !coworkers.isEmpty
    }

    // MARK: - WebSocket Connection

    private func connect() {
        guard let url = URL(string: "wss://wss-primary.slack.com/?token=\(token)") else {
            print("Invalid Slack WebSocket URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("d=\(cookie)", forHTTPHeaderField: "Cookie")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        isConnected = true

        print("Slack WebSocket connecting...")
        receiveMessage()
        scheduleReconnect()

        // Send presence subscription after a brief delay to ensure connection is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendPresenceSubscription()
        }
    }

    private func sendPresenceSubscription() {
        let userIds = Array(coworkers.keys)
        guard !userIds.isEmpty else { return }

        let subscribeMessage: [String: Any] = [
            "type": "presence_sub",
            "ids": userIds,
            "id": messageId,
        ]
        messageId += 1

        guard let data = try? JSONSerialization.data(withJSONObject: subscribeMessage),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            print("Failed to serialize presence_sub message")
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("Failed to send presence_sub: \(error)")
            } else {
                print("Sent presence subscription for \(userIds.count) users")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self?.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        if type == "presence_change" {
            handlePresenceChange(json)
        } else if type == "user_status_changed" {
            handleStatusChange(json)
        }
    }

    private func handlePresenceChange(_ json: [String: Any]) {
        let presence = json["presence"] as? String

        // Handle batch response (initial subscription response)
        if let users = json["users"] as? [String] {
            DispatchQueue.main.async {
                if presence == "active" {
                    for userId in users where self.coworkers[userId] != nil {
                        self.onlineUsers.insert(userId)
                    }
                } else {
                    for userId in users {
                        self.onlineUsers.remove(userId)
                    }
                }
                self.updateInitials()
            }
            return
        }

        // Handle individual user update
        guard let userId = json["user"] as? String,
            coworkers[userId] != nil,
            let presence = presence
        else { return }

        DispatchQueue.main.async {
            if presence == "active" {
                self.onlineUsers.insert(userId)
            } else {
                self.onlineUsers.remove(userId)
            }
            self.updateInitials()
        }
    }

    private func handleStatusChange(_ json: [String: Any]) {
        guard let user = json["user"] as? [String: Any],
            let userId = user["id"] as? String,
            coworkers[userId] != nil,
            let profile = user["profile"] as? [String: Any]
        else { return }

        let statusEmoji = profile["status_emoji"] as? String ?? ""
        let inMeeting = meetingEmojis.contains(statusEmoji)

        DispatchQueue.main.async {
            if inMeeting {
                self.usersInMeeting.insert(userId)
            } else {
                self.usersInMeeting.remove(userId)
            }
            self.updateInitials()
        }
    }

    private func updateInitials() {
        // Check if "Me" user is active
        var meIsActive = false
        for (userId, name) in coworkers {
            if name == "Me" && onlineUsers.contains(userId) {
                meIsActive = true
                break
            }
        }
        isMeActive = meIsActive

        let initials =
            onlineUsers
            .compactMap { userId -> String? in
                guard let name = coworkers[userId], let first = name.first else { return nil }
                // Skip "Me" from initials display - shown as green dot instead
                if name == "Me" { return nil }
                var initial = String(first).uppercased()
                // Add underline for users in meetings when showMeetingStatus is enabled
                if showMeetingStatus && usersInMeeting.contains(userId) {
                    initial += "\u{0332}"  // Combining low line (underline)
                }
                return initial
            }
            .sorted { $0.first?.lowercased() ?? "" < $1.first?.lowercased() ?? "" }
            .joined()
        onlineInitials = initials
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(
            withTimeInterval: Defaults.reconnectInterval,
            repeats: false
        ) { [weak self] _ in
            self?.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self?.connect()
        }
        if let timer = reconnectTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
}
