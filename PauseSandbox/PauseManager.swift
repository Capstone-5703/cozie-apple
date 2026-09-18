//
//  PauseManager.swift
//  Cozie
//
//  Tracks pause state locally for the prototype.
//  暂停功能原型：本地记录暂停状态

import Foundation
import Combine

enum PauseEventType: String, Codable {
    case started = "pause_started"
    case updated = "pause_updated"
    case ended = "pause_ended"
}

enum ResumeTrigger: String, Codable {
    case manual
    case scheduled
}

struct PauseEvent: Codable {
    let eventID: UUID
    let pauseID: UUID
    
    let eventType: PauseEventType
    let occurredAt: Date
    
    let pauseStartDate: Date
    let plannedEndDate: Date?
    let reason: String
    var previousEndDate: Date? = nil
    var resumeTrigger: ResumeTrigger? = nil // only at the end of pause event
}

class PauseManager: ObservableObject {
    @Published private(set) var pauseID: UUID? = nil
    @Published private(set) var latestEvent: PauseEvent? = nil
    @Published private(set) var isPaused: Bool
    @Published private(set) var pauseEndDate: Date?
    @Published private(set) var pauseStartDate: Date? = nil
    @Published private(set) var pauseReason: String = ""

    private let pauseIDKey = "sandbox_pause_id"
    private let isPausedKey = "sandbox_pause_isPaused"
    private let pauseEndDateKey = "sandbox_pause_endDate"
    private let defaults = UserDefaults.standard
    private let pauseStartDateKey = "sandbox_pause_startDate"
    private let pauseReasonKey = "sandbox_pause_reason"

    init() {
        isPaused = defaults.bool(forKey: isPausedKey)
        pauseEndDate = defaults.object(forKey: pauseEndDateKey) as? Date
        pauseStartDate = defaults.object(forKey: pauseStartDateKey) as? Date
        pauseReason = defaults.string(forKey: pauseReasonKey) ?? ""
        
        if let savedID = defaults.string(forKey: pauseIDKey){
            pauseID = UUID(uuidString: savedID)
        }
    }

    //log
    private func recordEvent(_ event: PauseEvent) {
        latestEvent = event
        
        //get user info
        guard UserInteractor().currentUser != nil else {
            print("Pause log not written: current user is missing")
            return
        }
        
        do{
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let data = try encoder.encode(event)
            let json = String(decoding: data, as: UTF8.self)
            
            LoggerInteractor.shared.logInfo(
                action: "",
                info:json
            )
        }catch {
            print("Pause event encoding failed: \(error)")
        }
    }
    
    
    //Start pause & storage pause info. Pass nil to pause indefinitely.
    // endDate 传 nil 表示无限期暂停;
    func pause(until endDate: Date?, reason: String) {
        let startDate = Date()
        let newPauseID = UUID()
       
        
        defaults.set(newPauseID.uuidString, forKey: pauseIDKey)
        
        //update status
        isPaused = true
        pauseStartDate = startDate
        pauseEndDate = endDate
        pauseReason = reason
        pauseID = newPauseID
        
        //save info to userdefaults
        defaults.set(true, forKey: isPausedKey)
        defaults.set(startDate, forKey: pauseStartDateKey)
        defaults.set(reason, forKey: pauseReasonKey)
        
        if let endDate {
            defaults.set(endDate, forKey: pauseEndDateKey)
        } else {
            defaults.removeObject(forKey: pauseEndDateKey)
        }
        //create pause start event
        let event = PauseEvent(
            eventID: UUID(),
            pauseID: newPauseID,
            eventType: .started,
            occurredAt: startDate,
            pauseStartDate: startDate,
            plannedEndDate: endDate,
            reason: reason
        )
        
        recordEvent(event)
    }

    
    // modify endtime before the pause original endtime
    @discardableResult
    func updateEndDate(_ newEndDate: Date) -> Bool {
        // check the pause status is on, time is valid
        guard isPaused,
              newEndDate > Date(),
              let currentPauseID = pauseID,
              let startDate = pauseStartDate
        else{
            return false
        }
        
        //update new end date
        guard newEndDate != pauseEndDate else {
            return true
        }
        
        // store old time before update
        let oldEndDate = pauseEndDate
        
        pauseEndDate = newEndDate
        defaults.set(newEndDate, forKey: pauseEndDateKey)
        
        // save the event
        let event = PauseEvent(
            eventID: UUID(),
            pauseID: currentPauseID,
            eventType: .updated,
            occurredAt: Date(),
            pauseStartDate: startDate,
            plannedEndDate: newEndDate,
            reason: pauseReason,
            previousEndDate: oldEndDate
            )
            recordEvent(event)
            return true
    }
    
    // Manual resume
    // 手动恢复
    func resume(trigger: ResumeTrigger = .manual) {
        guard isPaused else {return}
        
        let endedAt = Date()
        
        if let currentPauseID = pauseID,
           let startDate = pauseStartDate {
            let event = PauseEvent(
                eventID: UUID(),
                pauseID: currentPauseID,
                eventType: .ended,
                occurredAt: endedAt,
                pauseStartDate: startDate,
                plannedEndDate: pauseEndDate,
                reason: pauseReason,
                resumeTrigger: trigger
            )
            recordEvent(event)
        }
        isPaused = false
        pauseID = nil
        pauseStartDate = nil
        pauseEndDate = nil
        pauseReason = ""

        defaults.set(false, forKey: isPausedKey)
        defaults.removeObject(forKey: pauseIDKey)
        defaults.removeObject(forKey: pauseStartDateKey)
        defaults.removeObject(forKey: pauseEndDateKey)
        defaults.removeObject(forKey: pauseReasonKey)
    }

    // Returns true if auto-resume was triggered.
    // 到期自动恢复，返回是否触发了恢复
    @discardableResult
    func autoResumeIfNeeded() -> Bool {
        guard isPaused, let pauseEndDate, Date() >= pauseEndDate else { return false }
        resume(trigger: .scheduled)
        return true
    }
}
