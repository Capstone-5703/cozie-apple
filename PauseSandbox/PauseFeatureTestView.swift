//
//  PauseFeatureTestView.swift
//  Cozie
//

import SwiftUI
import UserNotifications
import OneSignalFramework
import Combine

struct PauseFeatureTestView: View {

    @StateObject private var pauseManager = PauseManager()
    @StateObject private var reminderManager = ReminderManager()

    @State private var pauseEndDate = Date().addingTimeInterval(5 * 60)
    @State private var pauseReason = ""
    @State private var pendingCount = 0
    @State private var pushOptedIn = false
    @State private var logLines: [String] = []
    
    @State private var startNow = true
    @State private var pauseStartDate = Date()
    
    @State private var currentTime = Date()
    
    @State private var isSavingPause = false
    
    private var pauseStatus: PauseStatus {
        pauseManager.status(at: currentTime)
    }

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
                    switch pauseStatus {
                    case .noPause:
                        Text("No Pause")
                        
                    case .scheduled:
                        if let plan = pauseManager.plan{
                            Text("Scheduled, starts at \(plan.startDate.formatted())")
                        }
                        
                        Button("Cancel", role: .destructive){
                            cancelPause()
                        }.disabled(isSavingPause)
                        
                    case .active:
                        if let plan = pauseManager.plan{
                            Text("Active, ends at \(plan.endDate.formatted())")
                        }
                        Button("End Now"){
                            endPauseNow()
                        }.disabled(isSavingPause)
                    }
                    
                    TextField("Pause Reason", text: $pauseReason).disabled(pauseStatus == .active)
                    
                    if pauseStatus == .active{
                        // can't change startDate, after active
                        if let plan = pauseManager.plan{
                            Text("Started at \(plan.startDate.formatted())")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                        }
                    }else{
                        Toggle("Start now", isOn: $startNow)

                        if !startNow {
                            DatePicker(
                                "Start time",
                                selection: $pauseStartDate,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    }
                    
                    DatePicker(
                       "End time",
                       selection: $pauseEndDate,
                       displayedComponents: [.date, .hourAndMinute]
                   )
                    
                    Button("Save pause"){
                        savePause()
                    }.disabled( isSavingPause || pauseManager.storageError != nil)
                    
                    if let error = pauseManager.storageError{
                        Text(error).foregroundColor(.red)
                    }
                }
                
                Section("Test Reminder (Local)") {
                    
                    Button("Create Test Reminder") {
                        createTestReminder()
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
                            log("Please save or change a pause plan first")
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
                                        log("Planned start: \(savedEvent.pauseStartDate.formatted())")
                                        log("Recorded: \(savedEvent.occurredAt.formatted())")

                                        if let endDate = savedEvent.plannedEndDate {
                                            log("Planned end: \(endDate.formatted())")
                                        }

                                        if let previousEndDate = savedEvent.previousEndDate {
                                            log("Previous end: \(previousEndDate.formatted())")
                                        }
                                        
                                        if let actualEndDate = savedEvent.actualEndDate {
                                            log("Actual end: \(actualEndDate.formatted())")
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
                loadPauseDraft()
                
                initializeOneSignalIfNeeded()
                refreshPendingCount()
                refreshPushStatus()
                
            }
            .onReceive(
                Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            ) { date in
                let previousStatus = pauseManager.status(at: currentTime)
                currentTime = date
                let newStatus = pauseManager.status(at: date)
                if previousStatus != newStatus {
                    loadPauseDraft()
                }
            }
                
        }
    }

    // get the pause status to initial Onesignal push
    private func initializeOneSignalIfNeeded() {
        OneSignal.initialize(CommunicationKeys.oneSignalAppID.rawValue, withLaunchOptions: nil)
    }

    private func loadPauseDraft() {
        let now = Date()
        currentTime = now

        guard let plan = pauseManager.plan,
              plan.status(at: now) != .noPause else {
            startNow = true
            pauseStartDate = now
            pauseEndDate = now.addingTimeInterval(5 * 60)
            pauseReason = ""
            return
        }

        startNow = false
        pauseStartDate = plan.startDate
        pauseEndDate = plan.endDate
        pauseReason = plan.reason
    }

    @MainActor
    private func savePause() {
        guard !isSavingPause else { return }
        
        
        let requestedStart: Date?

        if pauseManager.status() == .active {
            requestedStart = pauseManager.plan?.startDate
        } else {
            requestedStart = startNow ? nil : pauseStartDate
        }

        do {
            let changed = try pauseManager.savePause(
                startDate: requestedStart,
                endDate: pauseEndDate,
                reason: pauseReason
            )

            log(changed ? "Pause plan saved" : "No changes to save")
            loadPauseDraft()
        } catch {
            log(error.localizedDescription)
        }
    }

    private func cancelPause() {
        do {
            try pauseManager.cancelPause()
            log("Scheduled pause cancelled")
            loadPauseDraft()
        } catch {
            log(error.localizedDescription)
        }
    }

    private func endPauseNow() {
        do {
            try pauseManager.endPauseNow()
            log("Pause ended manually")
            loadPauseDraft()
        } catch {
            log(error.localizedDescription)
        }
    }
    
    
    
    

    private func createTestReminder() {
        guard pauseManager.status() == .noPause else {
            log("Skipped: a pause plan is scheduled or active")
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
