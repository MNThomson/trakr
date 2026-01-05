import AppKit
import Foundation

class SlackPresenceMonitor: ObservableObject {

    // MARK: - Logging

    private static func log(_ message: String) {
        NSLog("[SlackPresence] %@", message)
    }

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
        static let heartbeatTimeout: TimeInterval = 300  // 5 minutes without messages = stale
        static let heartbeatCheckInterval: TimeInterval = 60  // Check every minute
    }

    // MARK: - Singleton

    static let shared = SlackPresenceMonitor()

    // MARK: - Published Properties

    @Published private(set) var onlineInitials: String = ""
    @Published private(set) var initialsInMeeting: Set<Character> = []
    @Published private(set) var initialsUnavailable: Set<Character> = []
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
    private var heartbeatTimer: Timer?
    private var slackAppCheckTimer: Timer?
    private var onlineUsers: Set<String> = []
    private var usersInMeeting: Set<String> = []
    private var usersUnavailable: Set<String> = []
    private var messageId: Int = 1
    private var isConnected: Bool = false

    // Message tracking for heartbeat monitoring
    private var lastMessageTime: Date?

    /// Emojis that indicate the user is in a meeting or huddle
    private let meetingEmojis = [":calendar:", ":spiral_calendar_pad:", ":date:", ":headphones:"]

    /// Emojis that indicate the user is unavailable (lunch, busy, etc.)
    private let unavailableEmojis = [
        ":yay-eating-hotdog:", ":sandwich:", ":no_entry:", ":fork_and_knife:", ":knife_fork_plate:",
    ]

    /// Keywords in status text that indicate unavailability
    private let unavailableKeywords = ["food", "lunch"]

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
        // Handle full system wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }
            Self.log("System wake, reconnecting")
            // Brief delay to let network come back up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.reconnect()
            }
        }

        // Handle display wake (screen turned on without full sleep)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }
            Self.log("Screen wake, reconnecting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.reconnect()
            }
        }
    }

    // MARK: - Errors

    enum ValidationError: LocalizedError {
        case invalidCredentials(String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials(let message):
                return message
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Public Methods

    /// Validates Slack credentials by calling the auth.test API
    /// - Returns: The team name on success
    /// - Throws: ValidationError if credentials are invalid or network fails
    func validateCredentials(cookie: String, token: String) async throws -> String {
        guard let url = URL(string: "https://slack.com/api/auth.test") else {
            throw ValidationError.invalidCredentials("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("d=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ValidationError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ValidationError.invalidCredentials("Invalid response from Slack")
        }

        guard httpResponse.statusCode == 200 else {
            throw ValidationError.invalidCredentials("HTTP error: \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.invalidCredentials("Invalid JSON response")
        }

        guard let ok = json["ok"] as? Bool, ok else {
            let error = json["error"] as? String ?? "Unknown error"
            throw ValidationError.invalidCredentials("Slack API error: \(error)")
        }

        let team = json["team"] as? String ?? "Unknown team"
        return team
    }

    func start() {
        guard isEnabled else { return }
        guard !cookie.isEmpty, !token.isEmpty, !coworkers.isEmpty else { return }
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
            Self.log("Slack app detected, connecting")
            connect()
        } else if !slackIsRunning && isConnected {
            Self.log("Slack app closed, disconnecting")
            disconnect()
        }
    }

    private func isSlackRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.tinyspeck.slackmacgap"
        }
    }

    private func disconnect() {
        if isConnected {
            Self.log("WebSocket disconnecting")
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        onlineUsers.removeAll()
        usersInMeeting.removeAll()
        usersUnavailable.removeAll()
        updateInitials()
    }

    func stop() {
        slackAppCheckTimer?.invalidate()
        slackAppCheckTimer = nil
        disconnect()
    }

    /// Clears online status immediately (green dots disappear) without full disconnect
    private func clearOnlineStatus() {
        onlineUsers.removeAll()
        usersInMeeting.removeAll()
        usersUnavailable.removeAll()
        isConnected = false
        updateInitials()
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

    // MARK: - WebSocket Connection

    private func connect() {
        guard let url = URL(string: "wss://wss-primary.slack.com/?token=\(token)") else {
            Self.log("Invalid WebSocket URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("d=\(cookie)", forHTTPHeaderField: "Cookie")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        isConnected = true

        // Initialize so heartbeat doesn't trigger immediately
        lastMessageTime = Date()

        Self.log("WebSocket connecting")
        receiveMessage()
        startHeartbeatMonitor()

        // Send presence subscription after a brief delay to ensure connection is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendPresenceSubscription()
            self?.fetchInitialStatuses()
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
            Self.log("Failed to serialize presence_sub message")
            return
        }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                Self.log("Failed to send presence_sub: \(error.localizedDescription)")
            } else {
                Self.log("WebSocket connected")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.lastMessageTime = Date()
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
                Self.log("WebSocket receive error: \(error.localizedDescription)")

                // Immediately clear online status so green dots disappear
                self?.clearOnlineStatus()

                // Reconnect after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.reconnect()
                }
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
        } else if type == "user_change" {
            handleUserChange(json)
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

        processUserStatus(userId: userId, profile: profile)
    }

    /// Handles user_change events from Slack WebSocket (profile/status updates)
    private func handleUserChange(_ json: [String: Any]) {
        guard let user = json["user"] as? [String: Any],
            let userId = user["id"] as? String,
            coworkers[userId] != nil,
            let profile = user["profile"] as? [String: Any]
        else { return }

        processUserStatus(userId: userId, profile: profile)
    }

    /// Processes user status from profile data (shared by handleStatusChange and handleUserChange)
    private func processUserStatus(userId: String, profile: [String: Any]) {
        let statusEmoji = profile["status_emoji"] as? String ?? ""
        let statusText = profile["status_text"] as? String ?? ""
        let inMeeting = meetingEmojis.contains(statusEmoji)
        let isUnavailable = checkUnavailable(emoji: statusEmoji, text: statusText)

        DispatchQueue.main.async {
            if inMeeting {
                self.usersInMeeting.insert(userId)
            } else {
                self.usersInMeeting.remove(userId)
            }

            if isUnavailable {
                self.usersUnavailable.insert(userId)
            } else {
                self.usersUnavailable.remove(userId)
            }

            self.updateInitials()
        }
    }

    /// Checks if status emoji or text indicates user is unavailable
    private func checkUnavailable(emoji: String, text: String) -> Bool {
        if unavailableEmojis.contains(emoji) {
            return true
        }
        let lowerText = text.lowercased()
        return unavailableKeywords.contains { lowerText.contains($0) }
    }

    /// Fetches the current status emoji for all coworkers on connection
    private func fetchInitialStatuses() {
        let userIds = Array(coworkers.keys)
        guard !userIds.isEmpty else { return }

        for userId in userIds {
            guard let url = URL(string: "https://slack.com/api/users.profile.get?user=\(userId)")
            else {
                continue
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("d=\(cookie)", forHTTPHeaderField: "Cookie")

            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                guard let self = self,
                    let data = data,
                    error == nil,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let ok = json["ok"] as? Bool, ok,
                    let profile = json["profile"] as? [String: Any]
                else { return }

                let statusEmoji = profile["status_emoji"] as? String ?? ""
                let statusText = profile["status_text"] as? String ?? ""
                let inMeeting = self.meetingEmojis.contains(statusEmoji)
                let isUnavailable = self.checkUnavailable(emoji: statusEmoji, text: statusText)

                DispatchQueue.main.async {
                    if inMeeting {
                        self.usersInMeeting.insert(userId)
                    } else {
                        self.usersInMeeting.remove(userId)
                    }

                    if isUnavailable {
                        self.usersUnavailable.insert(userId)
                    } else {
                        self.usersUnavailable.remove(userId)
                    }

                    self.updateInitials()
                }
            }.resume()
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

        var meetingInitials: Set<Character> = []
        var unavailableInitials: Set<Character> = []
        let initials =
            onlineUsers
            .compactMap { userId -> String? in
                guard let name = coworkers[userId], let first = name.first else { return nil }
                // Skip "Me" from initials display - shown as green dot instead
                if name == "Me" { return nil }
                let initial = Character(String(first).uppercased())
                // Track which initials are in meetings when showMeetingStatus is enabled
                if showMeetingStatus && usersInMeeting.contains(userId) {
                    meetingInitials.insert(initial)
                }
                // Track which initials are unavailable when showMeetingStatus is enabled
                if showMeetingStatus && usersUnavailable.contains(userId) {
                    unavailableInitials.insert(initial)
                }
                return String(initial)
            }
            .sorted { $0.lowercased() < $1.lowercased() }
            .joined()
        onlineInitials = initials
        initialsInMeeting = meetingInitials
        initialsUnavailable = unavailableInitials
    }

    /// Starts monitoring for stale connections - only reconnects if no messages received
    private func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()

        // Use regular Timer - if it gets throttled, that's fine, we just check less often
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Defaults.heartbeatCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkHeartbeat()
        }
        if let timer = heartbeatTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    /// Checks if connection is stale (no messages for too long) and reconnects if needed
    private func checkHeartbeat() {
        guard isConnected, let lastMsg = lastMessageTime else { return }

        let timeSinceLastMessage = Date().timeIntervalSince(lastMsg)

        if timeSinceLastMessage > Defaults.heartbeatTimeout {
            Self.log("Connection stale, reconnecting...")
            clearOnlineStatus()
            reconnect()
        }
    }
}
