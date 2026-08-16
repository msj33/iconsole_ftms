import Foundation
import IOBluetooth
import CoreBluetooth
import Darwin

private var lastRenderedDashboardLines: [String] = []
private let dashboardTopRow = 1
private var activeStdinState: StdinState?

private func performTerminalCleanup(clearDashboard: Bool) {
    if let state = activeStdinState {
        restoreStdin(state)
        activeStdinState = nil
    }
    endLiveDashboard(clear: clearDashboard)
}

@main
struct IconsoleFTMSApp {

    static func main() {
        let tuning = BridgeTuning()
        atexit {
            performTerminalCleanup(clearDashboard: false)
        }

        print()
        print("==============================================")
        print(" iCONSOLE+ -> FTMS BRIDGE")
        print("==============================================")
        print("Verbose logs:", verboseLogging ? "ON" : "OFF")
        print("Speed factor:", String(format: "%.5f", tuning.currentSpeedFactor))
        print("Power factor:", String(format: "%.5f", tuning.currentPowerFactor))
        print("Resistance levels:", "\(minResistanceLevel)...\(maxResistanceLevel)")
        print("Grade scale up:", String(format: "%.3f", tuning.currentGradeScaleUp))
        print("Grade scale down:", String(format: "%.3f", tuning.currentGradeScaleDown))
        print("Grade deadband (%):", String(format: "%.3f", gradeCommandDeadbandPercent))
        print("Power watts/level:", String(format: "%.3f", powerWattsPerResistanceLevel))
        print("Prefer grade over power:", preferGradeOverTargetPower ? "YES" : "NO")
        print("Target power suppress s:", String(format: "%.2f", targetPowerSuppressWindowSeconds))
        print()

        guard !bikeMacAddress.isEmpty else {
            print("❌ Missing environment variable: \(bikeMacAddressEnvKey)")
            print("Example: ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ./iconsole_ftms")
            exit(1)
        }

        guard let device = IOBluetoothDevice(addressString: bikeMacAddress) else {
            print("❌ Device not found for address: \(bikeMacAddress)")
            exit(1)
        }

        print("Device:", device.nameOrAddress ?? "unknown")
        print("Address:", device.addressString ?? "unknown")
        print()

        print("SDP:", device.performSDPQuery(nil))
        print()

        let rfcommDelegate = RFCOMMDelegate()
        var channel: IOBluetoothRFCOMMChannel?

        let result = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: rfcommDelegate)

        guard let channel else {
            print("❌ RFCOMM failed:", result)
            exit(2)
        }

        print("RFCOMM channel:", channel.getID())
        print("MTU:", channel.getMTU())
        print("OPEN:", channel.isOpen())
        print()

        channel.setDelegate(rfcommDelegate)

        guard initialize(channel) else {
            print()
            print("❌ iConsole initialization failed")
            channel.close()
            exit(3)
        }

        print()
        print("Starting bike...")

        let startResult = send(channel, START)
        print("START write:", startResult)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        let currentLevel = minResistanceLevel
        setResistance(channel, level: currentLevel)

        let ftms = FTMSPeripheral(channel: channel, tuning: tuning)

        withExtendedLifetime(ftms) {
            let stdinState = enableRawNonBlockingStdin()
            activeStdinState = stdinState
            var lastTelemetry: BikeTelemetry?
            var statusLine = "Waiting for bike telemetry and FTMS commands..."
            var lastRenderAt = Date.distantPast
            var needsRender = true
            beginLiveDashboard()
            defer {
                performTerminalCleanup(clearDashboard: true)
            }
            var shouldQuit = false

            while !shouldQuit {
                let readResult = send(channel, READ)

                if readResult != kIOReturnSuccess {
                    statusLine = "READ failed: \(readResult)"
                    needsRender = true
                    break
                }

                if let packet = waitForBikePacket(
                    delegate: rfcommDelegate,
                    timeout: bikeReadResponseWaitSeconds,
                    pollInterval: bikeReadPollIntervalSeconds
                ), let decoded = decodeTelemetry(packet) {
                    lastTelemetry = decoded
                    ftms.sendTelemetry(decoded)
                    needsRender = true
                }

                let bytes = readAvailableInputBytes()
                if !bytes.isEmpty {
                    for byte in bytes {
                        switch byte {
                        case 43, 61: // +, =
                            ftms.increaseManualResistance()
                            statusLine = "Manual resistance up"
                            needsRender = true
                        case 45, 95: // -, _
                            ftms.decreaseManualResistance()
                            statusLine = "Manual resistance down"
                            needsRender = true
                        case 49...57:
                            ftms.setManualResistance(level: Int(byte - 48))
                            statusLine = "Manual resistance set"
                            needsRender = true
                        case 115: // s
                            tuning.increaseSpeedFactor()
                            statusLine = "Speed factor increased"
                            needsRender = true
                        case 83: // S
                            tuning.decreaseSpeedFactor()
                            statusLine = "Speed factor decreased"
                            needsRender = true
                        case 112: // p
                            tuning.increasePowerFactor()
                            statusLine = "Power factor increased"
                            needsRender = true
                        case 80: // P
                            tuning.decreasePowerFactor()
                            statusLine = "Power factor decreased"
                            needsRender = true
                        case 103: // g
                            tuning.increaseGradeScale()
                            statusLine = "Grade scale increased"
                            needsRender = true
                        case 71: // G
                            tuning.decreaseGradeScale()
                            statusLine = "Grade scale decreased"
                            needsRender = true
                        case 118: // v
                            statusLine = "Tuning: \(tuning.snapshotString())"
                            needsRender = true
                        case 113: // q
                            statusLine = "Stopping..."
                            shouldQuit = true
                        default:
                            break
                        }
                    }
                }

                let now = Date()
                if needsRender || now.timeIntervalSince(lastRenderAt) >= uiRefreshIntervalSeconds {
                    renderLiveDashboard(
                        bike: lastTelemetry,
                        ftms: ftms,
                        tuning: tuning,
                        status: statusLine
                    )
                    lastRenderAt = now
                    needsRender = false
                }

                RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
            }
        }

        print()
        print()
        print("Stopping bike...")

        let stopResult = send(channel, STOP)
        print("STOP:", stopResult)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        channel.close()

        print("Disconnected.")
    }
}

struct StdinState {
    let flags: Int32?
    let termios: Darwin.termios?
}

func enableRawNonBlockingStdin() -> StdinState {
    let fd = STDIN_FILENO
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    var original = Darwin.termios()
    let termRead = tcgetattr(fd, &original)
    guard termRead == 0 else {
        return StdinState(flags: flags >= 0 ? flags : nil, termios: nil)
    }

    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    raw.c_iflag &= ~tcflag_t(ICRNL)
    _ = tcsetattr(fd, TCSANOW, &raw)

    return StdinState(flags: flags >= 0 ? flags : nil, termios: original)
}

func restoreStdin(_ state: StdinState) {
    if let flags = state.flags {
        _ = fcntl(STDIN_FILENO, F_SETFL, flags)
    }

    if var term = state.termios {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &term)
    }
}

func readAvailableInputBytes(maxBytes: Int = 64) -> [UInt8] {
    guard maxBytes > 0 else {
        return []
    }

    var buffer = [UInt8](repeating: 0, count: maxBytes)
    let count = Darwin.read(STDIN_FILENO, &buffer, maxBytes)

    if count > 0 {
        return Array(buffer.prefix(count))
    }

    if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        return []
    }

    return []
}

func waitForBikePacket(
    delegate: RFCOMMDelegate,
    timeout: TimeInterval,
    pollInterval: TimeInterval
) -> Data? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if let packet = delegate.takeLatestPacket() {
            return packet
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
    }

    return delegate.takeLatestPacket()
}

func renderLiveDashboard(
    bike: BikeTelemetry?,
    ftms: FTMSPeripheral,
    tuning: BridgeTuning,
    status: String
) {
    let leftWidth = 58
    let totalRows = 26

    var leftLines = ["BIKE (RFCOMM)"]
    if let bike {
        leftLines.append(String(format: "Time         : %02d:%02d:%02d", bike.hour, bike.minute, bike.second))
        leftLines.append(String(format: "Speed        : %5.1f km/h", bike.speed))
        leftLines.append(String(format: "Cadence      : %3d RPM", bike.rpm))
        leftLines.append(String(format: "Power        : %5.1f W", bike.power))
        leftLines.append(String(format: "Resistance   : %2d", bike.resistance))
        leftLines.append(String(format: "Distance     : %5.1f km", bike.distance))
        leftLines.append(String(format: "Calories     : %4d kcal", bike.calories))
        leftLines.append(String(format: "Heart rate   : %3d bpm", bike.heartRate))
    } else {
        leftLines.append("Waiting for telemetry...")
    }

    var rightLines = ["FTMS (from app)"]
    rightLines.append("Last event    : \(ftms.latestEvent)")
    rightLines.append("Last opcode   : \(ftms.latestControlPointOpcodeHex ?? "-")")
    rightLines.append("Source        : \(ftms.latestResistanceSource)")
    rightLines.append("Cmd resistance: \(ftms.currentCommandedResistanceLevel)")
    rightLines.append(String(format: "RGRD          : %@", formatSignedPercent(ftms.latestReceivedSimulationGradePercent)))
    rightLines.append(String(format: "AGRD          : %@", formatSignedPercent(ftms.latestSimulationGradePercent)))
    rightLines.append(String(format: "WND           : %@", formatSignedMetersPerSecond(ftms.latestReceivedSimulationWindSpeedMetersPerSecond)))
    rightLines.append(String(format: "CRR           : %@", formatDecimal(ftms.latestReceivedSimulationCRR, places: 4)))
    rightLines.append(String(format: "CW            : %@", formatDecimal(ftms.latestReceivedSimulationCW, places: 2)))
    rightLines.append(String(format: "TPWR          : %@", formatWatts(ftms.latestTargetPowerWatts)))
    rightLines.append(String(format: "TRES          : %@", formatPercent(ftms.latestTargetResistancePercent)))

    let maxRows = max(leftLines.count, rightLines.count)
    var lines: [String] = []
    lines.append("iCONSOLE+ -> FTMS LIVE DASHBOARD")
    lines.append("Status: \(status)")
    lines.append("Controls: +/-/1-9 resistance | s/S speed | p/P power | g/G grade | v values | q quit")
    lines.append(String(repeating: "-", count: leftWidth + 2 + 58))

    for idx in 0..<maxRows {
        let left = idx < leftLines.count ? leftLines[idx] : ""
        let right = idx < rightLines.count ? rightLines[idx] : ""
        lines.append("\(padRight(left, width: leftWidth)) | \(right)")
    }

    lines.append(String(repeating: "-", count: leftWidth + 2 + 58))
    lines.append(
        String(
            format: "Tuning: SF %.2f | PF %.2f | GSU %.2f | GSD %.2f",
            tuning.currentSpeedFactor,
            tuning.currentPowerFactor,
            tuning.currentGradeScaleUp,
            tuning.currentGradeScaleDown
        )
    )

    while lines.count < totalRows {
        lines.append("")
    }
    if lines.count > totalRows {
        lines = Array(lines.prefix(totalRows))
    }

    var output = ""
    let maxLineCount = max(lines.count, lastRenderedDashboardLines.count)

    for idx in 0..<maxLineCount {
        let newLine = idx < lines.count ? lines[idx] : ""
        let oldLine = idx < lastRenderedDashboardLines.count ? lastRenderedDashboardLines[idx] : nil

        guard oldLine != newLine else {
            continue
        }

        let row = dashboardTopRow + idx
        output += "\u{001B}[\(row);1H\u{001B}[2K\(newLine)"
    }

    if output.isEmpty {
        return
    }

    lastRenderedDashboardLines = lines
    print(output, terminator: "")
    fflush(stdout)
}

func padRight(_ value: String, width: Int) -> String {
    if value.count >= width {
        return String(value.prefix(width))
    }
    return value + String(repeating: " ", count: width - value.count)
}

func formatSignedPercent(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%+.2f%%", value)
}

func formatPercent(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.2f%%", value)
}

func formatSignedMetersPerSecond(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%+.3f m/s", value)
}

func formatWatts(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.0f W", value)
}

func formatDecimal(_ value: Double?, places: Int) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(places)f", value)
}

func beginLiveDashboard() {
    lastRenderedDashboardLines = []
    print("\u{001B}[?25l\u{001B}[2J\u{001B}[H", terminator: "")
}

func endLiveDashboard(clear: Bool) {
    if clear {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
    }
    lastRenderedDashboardLines = []
    print("\u{001B}[?25h", terminator: "")
}
