//
//  PauseFeatureTestView.swift
//  Cozie
//

import SwiftUI
import UserNotifications
import OneSignalFramework

struct PauseFeatureTestView: View {

    @StateObject private var pauseManager = PauseManager()
    @StateObject private var reminderManager = ReminderManager()

    @State private var pauseEndDate = Date().addingTimeInterval(5 * 60)
    @State private var pendingCount = 0
    @State private var pushOptedIn = false
    @State private var logLines: [String] = []

    var body: some View {
        NavigationView {
            Form {
                Section("Notification Permission") {
                    Button("Request Permission") {
                        reminderManager.askForPermission { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let granted):
                                    log(granted ? "Permission granted" : "Permission denied")
                                case .failure(let error):
                                    log("Permission error: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }

                Section("Pause State") {
                    Toggle("Pause Notifications", isOn: Binding(
                        get: { pauseManager.isPaused },
                        set: { $0 ? startPause() : resume() }
                    ))

                    if pauseManager.isPaused {
                        DatePicker("Resume At", selection: $pauseEndDate, displayedComponents: [.date, .hourAndMinute])
                        if let endDate = pauseManager.pauseEndDate {
                            Text("Auto-resumes at \(endDate.formatted())")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Test Reminder (Local)") {
                    Button("Create Test Reminder") {
                        createTestReminder()
                    }
                    Button("Check Auto-Resume") {
                        if pauseManager.autoResumeIfNeeded() {
                            log("Auto-resumed")
                            createTestReminder()
                            refreshPushStatus()
                        } else {
                            log("Not due yet")
                        }
                        refreshPendingCount()
                    }
                    Button("Refresh Pending Count") {
                        refreshPendingCount()
                    }
                    Text("Pending notifications: \(pendingCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Remote Push (OneSignal)") {
                    Button("Refresh Push Status") {
                        refreshPushStatus()
                    }
                    Text(pushOptedIn ? "Push subscription: ON" : "Push subscription: OFF")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Log") {
                    ForEach(logLines.reversed(), id: \.self) { line in
                        Text(line).font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Pause Sandbox")
            .onAppear {
                initializeOneSignalIfNeeded()
                refreshPendingCount()
                refreshPushStatus()
            }
        }
    }

    // Bypasses HomeCoordinator, so init OneSignal here directly.
    private func initializeOneSignalIfNeeded() {
        OneSignal.initialize(CommunicationKeys.oneSignalAppID.rawValue, withLaunchOptions: nil)
        OneSignal.User.pushSubscription.optIn()
        log("OneSignal initialized")
    }

    private func startPause() {
        pauseManager.pause(until: pauseEndDate)

        reminderManager.removeWatchNotification {
            DispatchQueue.main.async {
                log("Local reminder cancelled")
                refreshPendingCount()
            }
        }

        OneSignal.User.pushSubscription.optOut()
        log("Push subscription opted out")
        refreshPushStatus()
    }

    private func resume() {
        pauseManager.resume()
        log("Resumed")
        createTestReminder()

        OneSignal.User.pushSubscription.optIn()
        log("Push subscription opted in")
        refreshPushStatus()
    }

    private func createTestReminder() {
        guard !pauseManager.isPaused else {
            log("Skipped: currently paused")
            return
        }

        let today = DayModel(id: 0, title: currentWeekday(), isSelected: true)
        let now = Date()
        let minutesNow = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)

        let reminder = Reminder(identifier: "sandbox-test",
                                 day: today,
                                 timeStart: minutesNow + 1,
                                 timeEnd: minutesNow + 10,
                                 interval: 1)

        reminderManager.createReminderNotification(list: [reminder])
        log("Test reminder created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshPendingCount() }
    }

    private func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async { pendingCount = requests.count }
        }
    }

    private func refreshPushStatus() {
        pushOptedIn = OneSignal.User.pushSubscription.optedIn
    }

    private func currentWeekday() -> DayIndex {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
    }

    private func log(_ text: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.append("[\(time)] \(text)")
    }
}

#Preview {
    PauseFeatureTestView()
}
