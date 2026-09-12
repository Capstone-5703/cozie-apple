//
//  PauseManager.swift
//  Cozie
//
//  Tracks pause state locally for the prototype.
//  暂停功能原型：本地记录暂停状态

import Foundation
import Combine

class PauseManager: ObservableObject {

    @Published private(set) var isPaused: Bool
    @Published private(set) var pauseEndDate: Date?

    private let isPausedKey = "sandbox_pause_isPaused"
    private let pauseEndDateKey = "sandbox_pause_endDate"
    private let defaults = UserDefaults.standard

    init() {
        isPaused = defaults.bool(forKey: isPausedKey)
        pauseEndDate = defaults.object(forKey: pauseEndDateKey) as? Date
    }

    // Pass nil to pause indefinitely.
    // endDate 传 nil 表示无限期暂停
    func pause(until endDate: Date?) {
        isPaused = true
        pauseEndDate = endDate
        defaults.set(true, forKey: isPausedKey)
        if let endDate {
            defaults.set(endDate, forKey: pauseEndDateKey)
        } else {
            defaults.removeObject(forKey: pauseEndDateKey)
        }
    }

    // Manual resume
    // 手动恢复
    func resume() {
        isPaused = false
        pauseEndDate = nil
        defaults.set(false, forKey: isPausedKey)
        defaults.removeObject(forKey: pauseEndDateKey)
    }

    // Returns true if auto-resume was triggered.
    // 到期自动恢复，返回是否触发了恢复
    @discardableResult
    func autoResumeIfNeeded() -> Bool {
        guard isPaused, let pauseEndDate, Date() >= pauseEndDate else { return false }
        resume()
        return true
    }
}
