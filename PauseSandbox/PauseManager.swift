//
//  PauseManager.swift
//  Cozie
//
//  Tracks pause state locally for the prototype.
//  暂停功能原型：本地记录暂停状态

import Foundation
import Combine

enum PauseStatus{
    case noPause //not pause plan, or pause end
    case scheduled // saved the pause, but not start
    case active  // at the set pause time
}


struct PausePlan: Codable, Equatable {
    let id: UUID  // unique pause id
    var startDate: Date
    var endDate: Date
    var reason: String
    
    func status(at now: Date = Date()) -> PauseStatus {
        if now < endDate && now >= startDate {
            return .active
        }
        if now < startDate {
            return .scheduled
        }
        
        return .noPause
    }
}


enum PauseEventType: String, Codable {
    case saved = "pause_saved"
    case updated = "pause_updated"
    case cancelled = "pause_cancelled"
    case started = "pause_started"
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
    
    var previousStartDate: Date? = nil
    var previousEndDate: Date? = nil
    var previousReason: String? = nil
    var actualEndDate: Date? = nil
    var resumeTrigger: ResumeTrigger? = nil // only at the end of pause event
}

// show fail reason
struct PauseValidationError: LocalizedError{
    let message: String
    
    var errorDescription: String? {
        message
    }
}

class PauseManager: ObservableObject {
    @Published private(set) var plan: PausePlan?
    @Published private(set) var latestEvent: PauseEvent?
    @Published private(set) var storageError: String?
    
    private let defaults: UserDefaults
    private let planKey = "participation_pause_plan_v1"
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        guard let data = defaults.data(forKey: planKey) else {
            return
        }
        
        do{
            plan = try JSONDecoder().decode(
                PausePlan.self,
                from: data
            )
        } catch {
            storageError = "The saved pause plan could not be loaded."
        }
    }
    
    //no plan - status 'no pause'; planed - conditinal status
    func status(at now: Date = Date()) -> PauseStatus {
        guard let plan = plan else {
            return .noPause
        }
        return plan.status(at: now)
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
    
    
    //Start date == nil, means start from now
    // true - change; false - no change
    @discardableResult
    func savePause(
        startDate: Date?,
        endDate: Date,
        reason: String
    )throws -> Bool {
        guard storageError == nil else {
            throw PauseValidationError(
                message: "The saved pause plan could not be loaded."
            )
        }
        
        let now = Date()
        let trimmedReason = reason.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        guard !trimmedReason.isEmpty else {
            throw PauseValidationError(
                message: "Please enter a pause reason."
            )
        }
        
        let existingPlan: PausePlan?
        if let currentPlan = plan,
           currentPlan.status(at: now) != .noPause {
            existingPlan = currentPlan
        } else {
            existingPlan = nil
        }
        
        let resolvedStart: Date
        
        if let existingPlan = existingPlan,
           existingPlan.status(at: now) == .active{
            if let requestedStart = startDate,
               requestedStart != existingPlan.startDate {
                throw PauseValidationError(
                    message: "The start time cannot be changed during a pause."
                )
            }
            
            guard trimmedReason == existingPlan.reason else{
                throw PauseValidationError(
                    message: "The reason cannot be changed during a pause."
                )
            }
            
            resolvedStart = existingPlan.startDate
        }else{
            resolvedStart = startDate ?? now
            
            guard resolvedStart >= now else{
                throw PauseValidationError(
                    message: "Choose Now or a future start time."
                )
            }
        }
        
        guard endDate > resolvedStart, endDate > now else {
                throw PauseValidationError(
                    message: "The end time must be in the future and after the start time."
                )
            }

            let newPlan = PausePlan(
                id: existingPlan?.id ?? UUID(),
                startDate: resolvedStart,
                endDate: endDate,
                reason: trimmedReason
        )
        
        // advoid duplicate log
        if let existingPlan = existingPlan,
               newPlan == existingPlan {
                return false
        }
        
        //update
        let data = try JSONEncoder().encode(newPlan)
            defaults.set(data, forKey: planKey)
            plan = newPlan

        let event = PauseEvent(
            eventID: UUID(),
            pauseID: newPlan.id,
            eventType: existingPlan == nil ? .saved : .updated,
            occurredAt: now,
            pauseStartDate: newPlan.startDate,
            plannedEndDate: newPlan.endDate,
            reason: newPlan.reason,
            previousStartDate: existingPlan?.startDate,
            previousEndDate: existingPlan?.endDate,
            previousReason: existingPlan?.reason
        )

        recordEvent(event)
        return true
    }
    
    // Cancel scheduled pause plan
    func cancelPause() throws {
        let now = Date()
        
        guard let currentPlan = plan,
              currentPlan.status(at: now) == .scheduled else {
            throw PauseValidationError(
                message: "Only a scheduled pause can be cancelled."
            )
        }
        // storage the original plan
        let event = PauseEvent(
            eventID: UUID(),
            pauseID: currentPlan.id,
            eventType: .cancelled,
            occurredAt: now,
            pauseStartDate: currentPlan.startDate,
            plannedEndDate: currentPlan.endDate,
            reason: currentPlan.reason
        )
        recordEvent(event)
        // clear the plan
        defaults.removeObject(forKey: planKey)
        plan = nil
        
    }
    
    
    // End now: end the pause immediately, when pause is actived
    func endPauseNow() throws {
        let now = Date()

        guard let currentPlan = plan,
              currentPlan.status(at: now) == .active else {
            throw PauseValidationError(
                message: "Only an active pause can be ended now."
            )
        }

        let event = PauseEvent(
            eventID: UUID(),
            pauseID: currentPlan.id,
            eventType: .ended,
            occurredAt: now,
            pauseStartDate: currentPlan.startDate,
            plannedEndDate: currentPlan.endDate,
            reason: currentPlan.reason,
            actualEndDate: now,
            resumeTrigger: .manual
        )

        recordEvent(event)

        defaults.removeObject(forKey: planKey)
        plan = nil
    }
    


    
}
