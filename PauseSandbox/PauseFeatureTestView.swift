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
    @State private var pauseReason = ""
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
                    TextField("Pause Reason", text: $pauseReason).disabled(pauseManager.isPaused)
                    
                    DatePicker("Resume At",
                               selection: $pauseEndDate,displayedComponents: [.date, .hourAndMinute])
                    
                    
                    //modify/save new end time button
                    if pauseManager.isPaused{
                        Button("Save End Time"){
                            let saved = pauseManager.updateEndDate(pauseEndDate)
                            if saved {
                                log("Pause end time updated")
                            } else {
                                log("Update failed: choose a future time")
                            }
                        }
                    }
                    
                    Toggle("Pause Notifications", isOn: Binding(
                        get: { pauseManager.isPaused },
                        set: { $0 ? startPause() : resume() }
                    ))

                    if pauseManager.isPaused {
                        
                        if let startDate = pauseManager.pauseStartDate {
                            Text("Pause start at \(startDate.formatted())")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let endDate = pauseManager.pauseEndDate {
                            Text("Auto-resumes at \(endDate.formatted())")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Pause Reason: \(pauseManager.pauseReason)")
                            .font(.caption)
                    }
                }

                Section("Test Reminder (Local)") {
                    
                    Button("Create Test Reminder") {
                        createTestReminder()
                    }
                    
                    Button("Check Auto-Resume") {
                        if pauseManager.autoResumeIfNeeded() {
                            log("Auto-resumed")
                            restoreNotificationsAfterResume()
                        } else {
                            log("Not expired pause to resume")
                        }
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
                    Button("Check Saved Pause Event"){
                        guard let event = pauseManager.latestEvent else {
                            log("Please start a new pause first")
                            return
                        }
                        
                        LoggerInteractor.shared.loggedInfo {
                            url, error in guard let url = url else {
                                log(error ?? "Log file not found")
                                return
                            }
                        
                            do {
                                let contents = try String(contentsOf: url, encoding: .utf8)

                                let data = Data(contents.utf8)
                                let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                                
                                // find the record
                                if let savedRecord = records.first(where: {
                                    ($0["eventID"] as? String) == event.eventID.uuidString
                                }) {
                                    let eventData = try JSONSerialization.data(withJSONObject: savedRecord)

                                    let decoder = JSONDecoder()
                                    decoder.dateDecodingStrategy = .iso8601
                                    
                                    // json to pause event
                                    let savedEvent = try decoder.decode(PauseEvent.self, from: eventData)

                                        log("Event: \(savedEvent.eventType.rawValue)")
                                        log("Pause ID: \(savedEvent.pauseID.uuidString)")
                                        log("Reason: \(savedEvent.reason)")
                                        log("Started: \(savedEvent.pauseStartDate.formatted())")
                                        log("Recorded: \(savedEvent.occurredAt.formatted())")

                                        if let endDate = savedEvent.plannedEndDate {
                                            log("Planned end: \(endDate.formatted())")
                                        }

                                        if let previousEndDate = savedEvent.previousEndDate {
                                            log("Previous end: \(previousEndDate.formatted())")
                                        }

                                        if let trigger = savedEvent.resumeTrigger {
                                            log("Resume trigger: \(trigger.rawValue)")
                                        }
                                    } else {
                                        log("Event not found yet. Try again shortly.")
                                    }
                                
                                } catch {
                                        log("Cannot read log: \(error.localizedDescription)")
                                        }
                            }
                        }
                    
                    
                    ForEach(logLines.reversed(), id: \.self) { line in
                        Text(line).font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Pause Sandbox")
            .onAppear {
                UserInteractor().prepareUser()
                if let savedEndDate = pauseManager.pauseEndDate{
                    pauseEndDate = savedEndDate
                }
                
                if pauseManager.isPaused{
                    pauseReason = pauseManager.pauseReason
                } else {
                    pauseReason = ""
                }
                
                initializeOneSignalIfNeeded()
                refreshPendingCount()
                refreshPushStatus()
            }
            .onChange(of: pauseManager.isPaused){ isPaused in
                if !isPaused{
                    pauseReason = ""
                }
            }
        }
    }

    // get the pause status to initial Onesignal push
    private func initializeOneSignalIfNeeded() {
        OneSignal.initialize(CommunicationKeys.oneSignalAppID.rawValue, withLaunchOptions: nil)
        if pauseManager.isPaused {
            OneSignal.User.pushSubscription.optOut()
            log("Paused: push opt-out requested")
        } else {
            OneSignal.User.pushSubscription.optIn()
            log("Not paused: push opt-in requested")
        }
    }

    private func startPause() {
        let reason = pauseReason.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !reason.isEmpty else {
            log("Please enter a reason")
            return
        }
        
        guard pauseEndDate > Date() else {
            log("Please choose a future end time")
            return
        }
        
        pauseManager.pause(
            until: pauseEndDate,
            reason: reason
        )

        reminderManager.removeWatchNotification {
            reminderManager.removePhoneNotification{
                DispatchQueue.main.async {
                    log("Watch and phone reminders cancelled")
                    refreshPendingCount()
                }
            }
        }

        OneSignal.User.pushSubscription.optOut()
        log("Push subscription opted out")
        refreshPushStatus()
    }
    
    // resume for manual & auto
    private func restoreNotificationsAfterResume(){
        guard !pauseManager.isPaused else { return }
        
        createTestReminder()
        
        OneSignal.User.pushSubscription.optIn()
        log("Push opt-in requested")
        
        refreshPushStatus()
        refreshPendingCount()
    }
    
    private func resume() {
        
        guard pauseManager.isPaused else {return}
        
        pauseManager.resume(trigger: .manual)
        log("Manually Resumed")
        
        restoreNotificationsAfterResume()
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
        
        let phoneReminder = PhoneReminder(
            identifier: "sandbox-phone-test",
            day: today,
            timeStart: reminder.timeStart
        )
        reminderManager.createPhoneReminder(list: [phoneReminder])
        
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
