import Foundation
import IOBluetooth
import CoreBluetooth

// Configuration: device + iConsole+ protocol packets

let bikeMacAddressEnvKey = "ICONSOLE_BIKE_MAC"
let bikeMacAddress = {
    guard let raw = ProcessInfo.processInfo.environment[bikeMacAddressEnvKey] else {
        return ""
    }

    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}()

let channelID: BluetoothRFCOMMChannelID = 6

let PING: [UInt8] = [
    0xF0, 0xA0, 0x01, 0x01, 0x92
]

let INIT_A0: [UInt8] = [
    0xF0, 0xA0, 0x02, 0x02, 0x94
]

let STATUS: [UInt8] = [
    0xF0, 0xA1, 0x01, 0x01, 0x93
]

let INIT_A3: [UInt8] = [
    0xF0, 0xA3, 0x01, 0x01, 0x01, 0x96
]

let INIT_A4: [UInt8] = [
    0xF0, 0xA4,
    0x01, 0x01,
    0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01,
    0x01, 0x01,
    0xA0
]

let START: [UInt8] = [
    0xF0, 0xA5,
    0x01, 0x01,
    0x02,
    0x99
]

let STOP: [UInt8] = [
    0xF0, 0xA5,
    0x01, 0x01,
    0x04,
    0x9B
]

let READ: [UInt8] = [
    0xF0, 0xA2,
    0x01, 0x01,
    0x94
]

// Set ICONSOLE_VERBOSE=1 to enable detailed bridge diagnostics.
let verboseLogging = ProcessInfo.processInfo.environment["ICONSOLE_VERBOSE"] == "1"
let minResistanceLevel = 1
let maxResistanceLevel = 30
let speedFactor = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_SPEED_FACTOR"] else {
        return 1.0
    }

    guard let value = Double(raw), value > 0 else {
        return 1.0
    }

    return value
}()
let powerFactor = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_POWER_FACTOR"] else {
        return 1.0
    }

    guard let value = Double(raw), value > 0 else {
        return 1.0
    }

    return value
}()
let gradeResistanceScaleUp = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_GRADE_SCALE_UP"] else {
        return 1.0
    }

    guard let value = Double(raw), value > 0 else {
        return 1.0
    }

    return value
}()
let gradeResistanceScaleDown = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_GRADE_SCALE_DOWN"] else {
        return 1.0
    }

    guard let value = Double(raw), value > 0 else {
        return 1.0
    }

    return value
}()
let gradeCommandDeadbandPercent = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_GRADE_DEADBAND_PERCENT"] else {
        return 0.10
    }

    guard let value = Double(raw), value >= 0 else {
        return 0.10
    }

    return value
}()
let powerWattsPerResistanceLevel = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_POWER_WATTS_PER_LEVEL"] else {
        return 25.0
    }

    guard let value = Double(raw), value > 0 else {
        return 25.0
    }

    return value
}()
let preferGradeOverTargetPower = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_PREFER_GRADE_OVER_POWER"] else {
        return true
    }

    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
}()
let targetPowerSuppressWindowSeconds = {
    guard let raw = ProcessInfo.processInfo.environment["ICONSOLE_TARGET_POWER_SUPPRESS_SECONDS"] else {
        return 8.0
    }

    guard let value = Double(raw), value >= 0 else {
        return 8.0
    }

    return value
}()
let bikeReadResponseWaitSeconds = 0.20
let bikeReadPollIntervalSeconds = 0.004
let loopIdleSleepSeconds = 0.001
let ftmsNotifyIntervalSeconds = 0.12
let uiRefreshIntervalSeconds = 0.20

func debugLog(_ message: @autoclosure () -> String) {
    guard verboseLogging else { return }
    print(message())
}

final class BridgeTuning {
    var currentSpeedFactor: Double
    var currentPowerFactor: Double
    var currentGradeScaleUp: Double
    var currentGradeScaleDown: Double

    init() {
        self.currentSpeedFactor = speedFactor
        self.currentPowerFactor = powerFactor
        self.currentGradeScaleUp = gradeResistanceScaleUp
        self.currentGradeScaleDown = gradeResistanceScaleDown
    }

    func increaseSpeedFactor() {
        currentSpeedFactor = min(3.0, currentSpeedFactor + 0.05)
    }

    func decreaseSpeedFactor() {
        currentSpeedFactor = max(0.20, currentSpeedFactor - 0.05)
    }

    func increasePowerFactor() {
        currentPowerFactor = min(3.0, currentPowerFactor + 0.05)
    }

    func decreasePowerFactor() {
        currentPowerFactor = max(0.20, currentPowerFactor - 0.05)
    }

    func increaseGradeScale() {
        currentGradeScaleUp = min(20.0, currentGradeScaleUp + 0.10)
        currentGradeScaleDown = min(20.0, currentGradeScaleDown + 0.10)
    }

    func decreaseGradeScale() {
        currentGradeScaleUp = max(0.10, currentGradeScaleUp - 0.10)
        currentGradeScaleDown = max(0.10, currentGradeScaleDown - 0.10)
    }

    func snapshotString() -> String {
        "speed=\(String(format: "%.2f", currentSpeedFactor)) power=\(String(format: "%.2f", currentPowerFactor)) gradeUp=\(String(format: "%.2f", currentGradeScaleUp)) gradeDown=\(String(format: "%.2f", currentGradeScaleDown))"
    }
}
