import Foundation
import CoreBluetooth
import IOBluetooth

// FTMS UUIDs and peripheral implementation

let FTMS_SERVICE_UUID = CBUUID(string: "1826")
let MACHINE_FEATURE_UUID = CBUUID(string: "2ACC")
let INDOOR_BIKE_DATA_UUID = CBUUID(string: "2AD2")
let RESISTANCE_RANGE_UUID = CBUUID(string: "2AD6")
let CONTROL_POINT_UUID = CBUUID(string: "2AD9")
let MACHINE_STATUS_UUID = CBUUID(string: "2ADA")
let CYCLING_POWER_SERVICE_UUID = CBUUID(string: "1818")
let CYCLING_POWER_MEASUREMENT_UUID = CBUUID(string: "2A63")
let CYCLING_POWER_FEATURE_UUID = CBUUID(string: "2A65")


final class FTMSPeripheral: NSObject, CBPeripheralManagerDelegate {
    enum ResistanceCommandSource: String {
        case startup = "START"
        case manual = "MAN"
        case targetResistance = "RES"
        case simulationGrade = "GRADE"
        case targetPower = "POWER"
    }

    private var manager: CBPeripheralManager!
    private var service: CBMutableService!
    private var machineFeature: CBMutableCharacteristic!
    private var indoorBikeData: CBMutableCharacteristic!
    private var resistanceRange: CBMutableCharacteristic!
    private var controlPoint: CBMutableCharacteristic!
    private var machineStatus: CBMutableCharacteristic!
    private var cyclingPowerMeasurement: CBMutableCharacteristic!
    private var cyclingPowerFeature: CBMutableCharacteristic!
    private var cyclingPowerService: CBMutableService!

    private let bikeChannel: IOBluetoothRFCOMMChannel
    private let tuning: BridgeTuning
    private var telemetry: BikeTelemetry?
    private var currentResistance: Int = minResistanceLevel
    private var simulationBaseResistance: Int = minResistanceLevel
    private var lastSimulationGradePercent: Double?
    private var latestReceivedGradePercent: Double?
    private var latestReceivedWindSpeedMetersPerSecond: Double?
    private var latestReceivedCRR: Double?
    private var latestReceivedCW: Double?
    private var lastSimulationCommandTime: Date?
    private var lastTargetPowerWatts: Double?
    private var lastTargetResistancePercent: Double?
    private var lastControlPointOpcode: UInt8?
    private var lastResistanceSource: ResistanceCommandSource = .startup
    private var lastEventSummary: String = "idle"
    private var hasBikeDataSubscriber = false
    private var hasControlPointSubscriber = false
    private var hasStatusSubscriber = false
    private var hasCyclingPowerSubscriber = false
    private var pendingBikeData: Data?
    private var pendingControlPointResponse: Data?
    private var pendingCyclingPowerData: Data?
    private var servicesPendingAdd = 0
    private var lastNotifyTime = Date.distantPast
    private let notifyInterval: TimeInterval = ftmsNotifyIntervalSeconds

    init(channel: IOBluetoothRFCOMMChannel, tuning: BridgeTuning) {

        self.bikeChannel = channel
        self.tuning = tuning

        super.init()

        lastEventSummary = "creating peripheral manager"

        manager = CBPeripheralManager(
            delegate: self,
            queue: DispatchQueue.main
        )
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {

        debugLog("Bluetooth state: \(peripheral.state.rawValue)")

        switch peripheral.state {
        case .poweredOn:
            lastEventSummary = "bluetooth powered on"
            setupFTMS()
        case .poweredOff:
            lastEventSummary = "bluetooth powered off"
        case .unauthorized:
            lastEventSummary = "bluetooth unauthorized"
        case .unsupported:
            lastEventSummary = "bluetooth unsupported"
        case .resetting:
            lastEventSummary = "bluetooth resetting"
        case .unknown:
            lastEventSummary = "bluetooth unknown"
        @unknown default:
            lastEventSummary = "bluetooth unknown state"
        }
    }

    private func setupFTMS() {

        lastEventSummary = "creating FTMS service"

        // Fitness Machine Feature (2ACC):
        // Keep cadence/power support and advertise target-setting capabilities
        // so apps can send resistance/simulation/power control commands.
        let featureValue = Data([
            0x02, 0x40, 0x00, 0x00,
            0x0C, 0xE0, 0x00, 0x00
        ])

        machineFeature = CBMutableCharacteristic(
            type: MACHINE_FEATURE_UUID,
            properties: [.read],
            value: featureValue,
            permissions: [.readable]
        )

        indoorBikeData = CBMutableCharacteristic(
            type: INDOOR_BIKE_DATA_UUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )

        resistanceRange = CBMutableCharacteristic(
            type: RESISTANCE_RANGE_UUID,
            properties: [.read],
            value: Data([
                0xF6, 0xFF,
                0x2C, 0x01,
                0x01, 0x00
            ]),
            permissions: [.readable]
        )

        controlPoint = CBMutableCharacteristic(
            type: CONTROL_POINT_UUID,
            properties: [.write, .indicate],
            value: nil,
            permissions: [.writeable]
        )

        machineStatus = CBMutableCharacteristic(
            type: MACHINE_STATUS_UUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )

        service = CBMutableService(type: FTMS_SERVICE_UUID, primary: true)

        service.characteristics = [
            machineFeature,
            indoorBikeData,
            resistanceRange,
            controlPoint,
            machineStatus
        ]

        cyclingPowerMeasurement = CBMutableCharacteristic(
            type: CYCLING_POWER_MEASUREMENT_UUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )

        cyclingPowerFeature = CBMutableCharacteristic(
            type: CYCLING_POWER_FEATURE_UUID,
            properties: [.read],
            value: Data([0x00, 0x00, 0x00, 0x00]),
            permissions: [.readable]
        )

        cyclingPowerService = CBMutableService(type: CYCLING_POWER_SERVICE_UUID, primary: true)
        cyclingPowerService.characteristics = [
            cyclingPowerMeasurement,
            cyclingPowerFeature
        ]

        servicesPendingAdd = 2
        manager.add(service)
        manager.add(cyclingPowerService)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {

        if let error {
            lastEventSummary = "failed adding FTMS service: \(error.localizedDescription)"
            return
        }

        servicesPendingAdd -= 1
        if servicesPendingAdd > 0 {
            return
        }

        lastEventSummary = "FTMS service added, starting advertising"

        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "iConsole FTMS",
            CBAdvertisementDataServiceUUIDsKey: [FTMS_SERVICE_UUID]
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            lastEventSummary = "advertising error: \(error.localizedDescription)"
            return
        }

        lastEventSummary = "advertising active, waiting for MyWhoosh"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {

        debugLog("")
        debugLog("FTMS READ:")
        debugLog("\(request.characteristic.uuid)")

        switch request.characteristic.uuid {
        case MACHINE_FEATURE_UUID:
            request.value = machineFeature.value
        case RESISTANCE_RANGE_UUID:
            request.value = resistanceRange.value
        case CYCLING_POWER_FEATURE_UUID:
            request.value = cyclingPowerFeature.value
        default:
            request.value = Data()
        }

        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {

        for request in requests {

            debugLog("")
            debugLog("==============================================")
            debugLog(" BLE WRITE")
            debugLog("==============================================")
            debugLog("Characteristic: \(request.characteristic.uuid)")

            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            let bytes = [UInt8](data)

            debugLog("Data: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")

            if request.characteristic.uuid == CONTROL_POINT_UUID {
                handleControlPoint(bytes)
            }

            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func handleControlPoint(_ bytes: [UInt8]) {

        guard !bytes.isEmpty else { return }

        let opcode = bytes[0]
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastControlPointOpcode = opcode

        debugLog("")
        debugLog("FTMS CONTROL POINT:")
        debugLog("RX: \(hex)")
        lastEventSummary = "cp \(String(format: "0x%02X", opcode)) \(hex)"

        switch opcode {
        case 0x00:
            debugLog("Request Control")
            sendControlPointResponse(requestOpcode: 0x00, resultCode: 0x01)
        case 0x01:
            debugLog("Reset")
            sendControlPointResponse(requestOpcode: 0x01, resultCode: 0x01)
        case 0x04:
            guard bytes.count >= 3 else {
                sendControlPointResponse(requestOpcode: opcode, resultCode: 0x03)
                return
            }

            let raw = Int16(bitPattern: UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            let resistance = Double(raw) / 10.0
            lastTargetResistancePercent = resistance
            debugLog("Set Target Resistance: \(resistance)")
            let level = Int(resistance.rounded())
            let clamped = max(minResistanceLevel, min(maxResistanceLevel, level))
            applyResistanceLevel(clamped, source: .targetResistance)
            simulationBaseResistance = clamped
            lastEventSummary = "target resistance \(String(format: "%.1f", resistance)) -> lvl \(clamped)"

            sendControlPointResponse(requestOpcode: opcode, resultCode: 0x01)
        case 0x05:
            guard bytes.count >= 3 else {
                sendControlPointResponse(requestOpcode: opcode, resultCode: 0x03)
                return
            }

            let raw = Int16(bitPattern: UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            let targetPower = Double(raw)
            debugLog("Set Target Power: \(raw) W")
            lastTargetPowerWatts = targetPower
            lastEventSummary = "target power \(String(format: "%.0f", targetPower))W"

            if preferGradeOverTargetPower,
               let lastSimulationCommandTime,
               Date().timeIntervalSince(lastSimulationCommandTime) <= targetPowerSuppressWindowSeconds {
                lastEventSummary = "target power ignored (recent grade)"
                sendControlPointResponse(requestOpcode: opcode, resultCode: 0x01)
                return
            }

            handleTargetPower(targetPower)
            sendControlPointResponse(requestOpcode: opcode, resultCode: 0x01)

        case 0x11:
            guard bytes.count >= 7 else {
                sendControlPointResponse(requestOpcode: opcode, resultCode: 0x03)
                return
            }

            // FTMS Set Indoor Bike Simulation Parameters:
            // [opcode][wind speed i16][grade i16][crr u8][cw u8]
            let windRaw = Int16(bitPattern: UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            let gradeRaw = Int16(bitPattern: UInt16(bytes[3]) | (UInt16(bytes[4]) << 8))
            let crrRaw = bytes[5]
            let cwRaw = bytes[6]
            let windSpeed = Double(windRaw) / 1000.0
            let gradePercent = Double(gradeRaw) / 100.0
            let crr = Double(crrRaw) / 10000.0
            let cw = Double(cwRaw) / 100.0
            latestReceivedGradePercent = gradePercent
            latestReceivedWindSpeedMetersPerSecond = windSpeed
            latestReceivedCRR = crr
            latestReceivedCW = cw
            lastSimulationCommandTime = Date()

            lastEventSummary = "sim grade \(String(format: "%+.2f", gradePercent))%"

            handleSimulationGrade(gradePercent)
            sendControlPointResponse(requestOpcode: opcode, resultCode: 0x01)
        case 0x07:
            debugLog("Start / Resume")
            let result = send(bikeChannel, START)
            debugLog("iConsole START: \(result)")
            sendControlPointResponse(requestOpcode: opcode, resultCode: result == kIOReturnSuccess ? 0x01 : 0x04)
        case 0x08:
            debugLog("Stop / Pause")
            let result = send(bikeChannel, STOP)
            debugLog("iConsole STOP: \(result)")
            sendControlPointResponse(requestOpcode: opcode, resultCode: result == kIOReturnSuccess ? 0x01 : 0x04)
        default:
            debugLog("Unsupported FTMS opcode: \(String(format: "0x%02X", opcode))")
            lastEventSummary = "unsupported opcode \(String(format: "0x%02X", opcode))"
            sendControlPointResponse(requestOpcode: opcode, resultCode: 0x02)
        }
    }

    private func handleSimulationGrade(_ gradePercent: Double) {
        if let lastSimulationGradePercent,
           abs(gradePercent - lastSimulationGradePercent) < gradeCommandDeadbandPercent {
            return
        }

        lastSimulationGradePercent = gradePercent

        let scale = gradePercent >= 0 ? tuning.currentGradeScaleUp : tuning.currentGradeScaleDown
        let delta = Int((gradePercent * scale).rounded())
        let target = max(minResistanceLevel, min(maxResistanceLevel, simulationBaseResistance + delta))

        lastEventSummary = "applied grade \(String(format: "%+.2f", gradePercent))% -> lvl \(target)"

        applyResistanceLevel(target, source: .simulationGrade)
    }

    private func handleTargetPower(_ targetPower: Double) {
        guard let telemetry else {
            lastEventSummary = "target power without telemetry"
            return
        }

        let deltaPower = targetPower - telemetry.power
        let deltaLevels = Int((deltaPower / powerWattsPerResistanceLevel).rounded())
        let target = max(minResistanceLevel, min(maxResistanceLevel, currentResistance + deltaLevels))

        lastEventSummary = "target power \(String(format: "%.0f", targetPower))W -> lvl \(target)"

        simulationBaseResistance = target
        applyResistanceLevel(target, source: .targetPower)
    }

    private func applyResistanceLevel(_ level: Int, source: ResistanceCommandSource) {
        guard level != currentResistance else {
            return
        }

        currentResistance = level
        lastResistanceSource = source
        setResistance(bikeChannel, level: level)
    }

    var currentCommandedResistanceLevel: Int {
        currentResistance
    }

    var latestSimulationGradePercent: Double? {
        lastSimulationGradePercent
    }

    var latestReceivedSimulationGradePercent: Double? {
        latestReceivedGradePercent
    }

    var latestReceivedSimulationWindSpeedMetersPerSecond: Double? {
        latestReceivedWindSpeedMetersPerSecond
    }

    var latestReceivedSimulationCRR: Double? {
        latestReceivedCRR
    }

    var latestReceivedSimulationCW: Double? {
        latestReceivedCW
    }

    var latestTargetPowerWatts: Double? {
        lastTargetPowerWatts
    }

    var latestTargetResistancePercent: Double? {
        lastTargetResistancePercent
    }

    var latestControlPointOpcodeHex: String? {
        guard let lastControlPointOpcode else {
            return nil
        }

        return String(format: "0x%02X", lastControlPointOpcode)
    }

    var latestResistanceSource: String {
        lastResistanceSource.rawValue
    }

    var latestEvent: String {
        lastEventSummary
    }

    func increaseManualResistance() {
        let target = min(maxResistanceLevel, currentResistance + 1)
        simulationBaseResistance = target
        lastEventSummary = "manual + -> lvl \(target)"
        applyResistanceLevel(target, source: .manual)
    }

    func decreaseManualResistance() {
        let target = max(minResistanceLevel, currentResistance - 1)
        simulationBaseResistance = target
        lastEventSummary = "manual - -> lvl \(target)"
        applyResistanceLevel(target, source: .manual)
    }

    func setManualResistance(level: Int) {
        let target = max(minResistanceLevel, min(maxResistanceLevel, level))
        simulationBaseResistance = target
        lastEventSummary = "manual set -> lvl \(target)"
        applyResistanceLevel(target, source: .manual)
    }

    private func sendControlPointResponse(requestOpcode: UInt8, resultCode: UInt8) {

        guard hasControlPointSubscriber else {
            debugLog("No Control Point subscriber")
            return
        }

        let response: [UInt8] = [0x80, requestOpcode, resultCode]
        let data = Data(response)

        debugLog("FTMS CP TX: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")

        let didSend = manager.updateValue(data, for: controlPoint, onSubscribedCentrals: nil)
        if didSend {
            pendingControlPointResponse = nil
        } else {
            pendingControlPointResponse = data
            debugLog("⚠️ FTMS CP backpressure: will retry when ready")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        switch characteristic.uuid {
        case INDOOR_BIKE_DATA_UUID:
            hasBikeDataSubscriber = true
            lastEventSummary = "subscribed indoor bike data"
            if let telemetry {
                sendTelemetry(telemetry)
            }
        case CYCLING_POWER_MEASUREMENT_UUID:
            hasCyclingPowerSubscriber = true
            lastEventSummary = "subscribed cycling power measurement"
            if let telemetry {
                sendTelemetry(telemetry)
            }
        case CONTROL_POINT_UUID:
            hasControlPointSubscriber = true
            lastEventSummary = "subscribed control point"
        case MACHINE_STATUS_UUID:
            hasStatusSubscriber = true
            lastEventSummary = "subscribed machine status"
        default:
            break
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if hasControlPointSubscriber, let pendingControlPointResponse {
            let didSend = peripheral.updateValue(pendingControlPointResponse, for: controlPoint, onSubscribedCentrals: nil)
            if didSend {
                self.pendingControlPointResponse = nil
            } else {
                return
            }
        }

        if hasBikeDataSubscriber, let pendingBikeData {
            let didSend = peripheral.updateValue(pendingBikeData, for: indoorBikeData, onSubscribedCentrals: nil)
            if didSend {
                self.pendingBikeData = nil
            } else {
                return
            }
        }

        if hasCyclingPowerSubscriber, let pendingCyclingPowerData {
            let didSend = peripheral.updateValue(pendingCyclingPowerData, for: cyclingPowerMeasurement, onSubscribedCentrals: nil)
            if didSend {
                self.pendingCyclingPowerData = nil
            } else {
                return
            }
        }

        if hasBikeDataSubscriber, let telemetry {
            sendTelemetry(telemetry)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        switch characteristic.uuid {
        case INDOOR_BIKE_DATA_UUID:
            hasBikeDataSubscriber = false
            lastEventSummary = "unsubscribed indoor bike data"
        case CYCLING_POWER_MEASUREMENT_UUID:
            hasCyclingPowerSubscriber = false
            lastEventSummary = "unsubscribed cycling power measurement"
        case CONTROL_POINT_UUID:
            hasControlPointSubscriber = false
            lastEventSummary = "unsubscribed control point"
        case MACHINE_STATUS_UUID:
            hasStatusSubscriber = false
            lastEventSummary = "unsubscribed machine status"
        default:
            break
        }
    }

    func sendTelemetry(_ t: BikeTelemetry) {

        telemetry = t

        guard hasBikeDataSubscriber else { return }

        let now = Date()
        if now.timeIntervalSince(lastNotifyTime) < notifyInterval {
            return
        }

        // FTMS Indoor Bike Data flags:
        // cadence present (bit 2) + instantaneous power present (bit 6).
        // Instantaneous speed is included by default.
        let flags: UInt16 = 0x0044

        var data = Data()

        data.append(UInt8(flags & 0xFF))
        data.append(UInt8((flags >> 8) & 0xFF))

        let calibratedSpeed = t.speed * tuning.currentSpeedFactor
        let speed = UInt16(max(0, min(65535, Int((calibratedSpeed * 100.0).rounded()))))
        data.append(UInt8(speed & 0xFF))
        data.append(UInt8((speed >> 8) & 0xFF))

        let cadence = UInt16(max(0, min(65535, t.rpm * 2)))
        data.append(UInt8(cadence & 0xFF))
        data.append(UInt8((cadence >> 8) & 0xFF))

        let calibratedPower = t.power * tuning.currentPowerFactor
        let powerRaw = Int16(max(-32768, min(32767, Int(calibratedPower.rounded()))))
        let powerBits = UInt16(bitPattern: powerRaw)
        data.append(UInt8(powerBits & 0xFF))
        data.append(UInt8((powerBits >> 8) & 0xFF))

        debugLog("FTMS TX: \(data.map { String(format: "%02X", $0) }.joined(separator: " ")) | speed: \(String(format: "%.1f", calibratedSpeed)) km/h (raw \(String(format: "%.1f", t.speed))) | cadence: \(t.rpm) | power: \(String(format: "%.1f", calibratedPower)) W (raw \(String(format: "%.1f", t.power))) | resistance: \(t.resistance)")

        if pendingBikeData != nil {
            pendingBikeData = data
            sendCyclingPowerMeasurement(powerWatts: calibratedPower)
            return
        }

        let didSend = manager.updateValue(data, for: indoorBikeData, onSubscribedCentrals: nil)
        if !didSend {
            pendingBikeData = data
            debugLog("⚠️ FTMS TX backpressure: updateValue returned false")
        } else {
            pendingBikeData = nil
            lastNotifyTime = now
        }

        sendCyclingPowerMeasurement(powerWatts: calibratedPower)
    }

    func sendMachineStatus() {

        guard hasStatusSubscriber else { return }

        let data = Data([0x01])

        manager.updateValue(data, for: machineStatus, onSubscribedCentrals: nil)
    }

    private func sendCyclingPowerMeasurement(powerWatts: Double) {
        guard hasCyclingPowerSubscriber else { return }

        let flags: UInt16 = 0x0000
        let powerRaw = Int16(max(-32768, min(32767, Int(powerWatts.rounded()))))
        let powerBits = UInt16(bitPattern: powerRaw)

        var data = Data()
        data.append(UInt8(flags & 0xFF))
        data.append(UInt8((flags >> 8) & 0xFF))
        data.append(UInt8(powerBits & 0xFF))
        data.append(UInt8((powerBits >> 8) & 0xFF))

        if pendingCyclingPowerData != nil {
            pendingCyclingPowerData = data
            return
        }

        let didSend = manager.updateValue(data, for: cyclingPowerMeasurement, onSubscribedCentrals: nil)
        if didSend {
            pendingCyclingPowerData = nil
        } else {
            pendingCyclingPowerData = data
            debugLog("⚠️ CPS TX backpressure: updateValue returned false")
        }
    }
}
