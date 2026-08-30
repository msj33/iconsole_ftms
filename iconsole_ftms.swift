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

        if bikeMacAddress.isEmpty {
            print("Bike selection: choose from paired Bluetooth devices")
        } else {
            print("Bike selection: \(bikeMacAddressEnvKey)=\(bikeMacAddress)")
        }
        print()

        var activeChannel: IOBluetoothRFCOMMChannel?
        var activeRFCOMMDelegate: RFCOMMDelegate?
        var activeFTMS: FTMSPeripheral?
        var stagedManualResistance = startupResistanceLevel
        var stagedAutoBaseResistance = defaultSimulationBaseResistanceLevel
        let localWebURL = "http://127.0.0.1:\(webServerPort)"
        let lanWebURL = discoverHomeNetworkIPv4().map { "http://\($0):\(webServerPort)" }
        let webState = SharedWebState(initial: WebDashboardSnapshot(
            appVersion: appVersion,
            status: "Starting web dashboard...",
            isConnected: false,
            localWebURL: localWebURL,
            lanWebURL: lanWebURL,
            bikeTime: "-",
            bikeSpeed: "-",
            bikeCadence: "-",
            bikePower: "-",
            bikeResistance: "-",
            bikeDistance: "-",
            bikeCalories: "-",
            bikeHeartRate: "-",
            event: "-",
            source: "-",
            opcode: "-",
            commandedResistance: stagedManualResistance,
            autoBaseResistance: stagedAutoBaseResistance,
            receivedGrade: "-",
            appliedGrade: "-",
            targetPower: "-",
            targetResistance: "-",
            tuning: tuning.snapshotString(),
            selectedDeviceAddress: bikeMacAddress.isEmpty ? nil : bikeMacAddress,
            deviceOptions: []
        ))
        let webCommandQueue = WebCommandQueue()
        let webServer = WebControlServer(port: webServerPort, state: webState, commandQueue: webCommandQueue)

        do {
            try webServer.start()
        } catch {
            print("❌ Failed to start web server on port \(webServerPort): \(error.localizedDescription)")
            exit(4)
        }

        defer {
            webServer.stop()
        }
        var lastTelemetry: BikeTelemetry?
        var statusLine = "Waiting for bike connection..."
        var webStatusLine = "Waiting for bike connection..."
        var lastSnapshotAt = Date.distantPast
        var shouldQuit = false
        var connectAttempt = 0
        var nextConnectAttemptAt = Date.distantPast
        var lastSelectedDeviceAddress: String?
        var lastSelectionFailureMessage: String?
        var lastConnectionStatusLine: String?
        var hasPrintedWebAccessInfo = false

        var selectedBikeAddress: String? = bikeMacAddress.isEmpty ? nil : bikeMacAddress

        while !shouldQuit {
            let now = Date()

            let webCommands = webCommandQueue.drain()
            if !webCommands.isEmpty {
                for command in webCommands {
                    switch command.action {
                    case "select_device":
                        guard let address = command.address, !address.isEmpty else {
                            break
                        }
                        if selectedBikeAddress == address, activeChannel != nil {
                            webStatusLine = "Already connected to selected bike."
                            statusLine = webStatusLine
                            break
                        }
                        if selectedBikeAddress == address, activeChannel == nil, now < nextConnectAttemptAt {
                            webStatusLine = "Already trying to connect to selected bike..."
                            statusLine = webStatusLine
                            break
                        }
                        selectedBikeAddress = address
                        webStatusLine = "Bike selected. Connecting..."
                        statusLine = "Bike selected (\(address)). Connecting..."
                        if let activeChannel {
                            activeChannel.close()
                            selfDrain()
                        }
                        nextConnectAttemptAt = Date.distantPast
                        hasPrintedWebAccessInfo = false
                    case "base_up":
                        stagedAutoBaseResistance = min(maxResistanceLevel, stagedAutoBaseResistance + 1)
                        if let activeFTMS {
                            activeFTMS.setAutoBaseResistance(level: stagedAutoBaseResistance)
                            statusLine = "Auto base resistance set to \(stagedAutoBaseResistance)"
                            webStatusLine = statusLine
                        } else {
                            statusLine = "Auto base set to \(stagedAutoBaseResistance) (applies on connect)"
                            webStatusLine = "Auto base set to \(stagedAutoBaseResistance). Applies on next connection."
                        }
                    case "base_down":
                        stagedAutoBaseResistance = max(minResistanceLevel, stagedAutoBaseResistance - 1)
                        if let activeFTMS {
                            activeFTMS.setAutoBaseResistance(level: stagedAutoBaseResistance)
                            statusLine = "Auto base resistance set to \(stagedAutoBaseResistance)"
                            webStatusLine = statusLine
                        } else {
                            statusLine = "Auto base set to \(stagedAutoBaseResistance) (applies on connect)"
                            webStatusLine = "Auto base set to \(stagedAutoBaseResistance). Applies on next connection."
                        }
                    case "manual_up":
                        stagedManualResistance = min(maxResistanceLevel, stagedManualResistance + 1)
                        if let activeFTMS {
                            activeFTMS.setManualResistance(level: stagedManualResistance)
                            statusLine = "Manual resistance set to \(stagedManualResistance)"
                            webStatusLine = statusLine
                        } else {
                            statusLine = "Manual resistance set to \(stagedManualResistance) (applies on connect)"
                            webStatusLine = "Manual resistance set to \(stagedManualResistance). Applies on next connection."
                        }
                    case "manual_down":
                        stagedManualResistance = max(minResistanceLevel, stagedManualResistance - 1)
                        if let activeFTMS {
                            activeFTMS.setManualResistance(level: stagedManualResistance)
                            statusLine = "Manual resistance set to \(stagedManualResistance)"
                            webStatusLine = statusLine
                        } else {
                            statusLine = "Manual resistance set to \(stagedManualResistance) (applies on connect)"
                            webStatusLine = "Manual resistance set to \(stagedManualResistance). Applies on next connection."
                        }
                    case "quit":
                        statusLine = "Stopping..."
                        webStatusLine = "Stopping app..."
                        shouldQuit = true
                    default:
                        break
                    }
                }
            }

            if shouldQuit {
                break
            }

            if activeChannel == nil, now >= nextConnectAttemptAt {
                connectAttempt += 1
                statusLine = "Connecting to bike (attempt \(connectAttempt))..."
                webStatusLine = "Trying to connect to bike (attempt \(connectAttempt))..."
                printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)

                let candidateDevices = resolvePreferredBikeCandidates(
                    selectedAddress: selectedBikeAddress,
                    allowBroadAutoDiscovery: false
                )
                guard !candidateDevices.isEmpty else {
                    let selectionFailure = bikeMacAddress.isEmpty
                        ? "No bike selected. Pick a device in the web interface."
                        : "Configured bike address not found: \(bikeMacAddress)"
                    statusLine = "\(selectionFailure) Retrying..."
                    webStatusLine = bikeMacAddress.isEmpty
                        ? "No bike selected. Choose a device from the web interface."
                        : "Configured bike address was not found. Retrying automatically..."
                    if selectionFailure != lastSelectionFailureMessage {
                        printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                        lastSelectionFailureMessage = selectionFailure
                    }
                    nextConnectAttemptAt = Date(timeIntervalSinceNow: rfcommReconnectIntervalSeconds)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
                    continue
                }
                lastSelectionFailureMessage = nil

                let selectedIndex = max(0, (connectAttempt - 1) % candidateDevices.count)
                let device = candidateDevices[selectedIndex]
                let selectedAddress = device.addressString ?? "unknown"
                selectedBikeAddress = device.addressString
                if selectedAddress != lastSelectedDeviceAddress {
                    print("Selected bike:", device.nameOrAddress ?? "unknown")
                    print("Address:", selectedAddress)
                    print()
                    lastSelectedDeviceAddress = selectedAddress
                }

                let delegate = RFCOMMDelegate()
                var candidateChannel: IOBluetoothRFCOMMChannel?
                let openResult = device.openRFCOMMChannelSync(
                    &candidateChannel,
                    withChannelID: channelID,
                    delegate: delegate
                )

                guard let candidateChannel, openResult == kIOReturnSuccess else {
                    statusLine = "Bike is not connectable right now. Retrying..."
                    webStatusLine = "Bike is currently unavailable. Retrying automatically..."
                    printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                    nextConnectAttemptAt = Date(timeIntervalSinceNow: rfcommReconnectIntervalSeconds)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
                    continue
                }

                candidateChannel.setDelegate(delegate)

                if !initialize(candidateChannel) {
                    statusLine = "Bike init failed. Retrying..."
                    webStatusLine = "Could not initialize bike. Retrying automatically..."
                    printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                    candidateChannel.close()
                    nextConnectAttemptAt = Date(timeIntervalSinceNow: rfcommReconnectIntervalSeconds)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
                    continue
                }

                let startResult = send(candidateChannel, START)

                if startResult != kIOReturnSuccess {
                    statusLine = "Bike start failed. Retrying..."
                    webStatusLine = "Could not start bike. Retrying automatically..."
                    printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                    candidateChannel.close()
                    nextConnectAttemptAt = Date(timeIntervalSinceNow: rfcommReconnectIntervalSeconds)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
                    continue
                }

                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                setResistance(candidateChannel, level: stagedManualResistance)

                let connectedFTMS = FTMSPeripheral(channel: candidateChannel, tuning: tuning)
                connectedFTMS.setAutoBaseResistance(level: stagedAutoBaseResistance)
                activeRFCOMMDelegate = delegate
                activeChannel = candidateChannel
                activeFTMS = connectedFTMS
                statusLine = "Connected. Streaming telemetry and accepting FTMS/web commands."
                webStatusLine = "Connected to bike."
                printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                if !hasPrintedWebAccessInfo {
                    printWebAccessInfo(port: webServerPort)
                    hasPrintedWebAccessInfo = true
                }
            }

            if let activeChannel, let activeRFCOMMDelegate, let activeFTMS {
                let readResult = send(activeChannel, READ)

                if readResult != kIOReturnSuccess {
                    statusLine = "Connection lost. Reconnecting..."
                    webStatusLine = "Connection lost. Reconnecting automatically..."
                    printConnectionStatus(statusLine, lastPrinted: &lastConnectionStatusLine)
                    activeChannel.close()
                    selfDrain()
                    nextConnectAttemptAt = Date(timeIntervalSinceNow: rfcommReconnectIntervalSeconds)
                    hasPrintedWebAccessInfo = false
                } else if let packet = waitForBikePacket(
                    delegate: activeRFCOMMDelegate,
                    timeout: bikeReadResponseWaitSeconds,
                    pollInterval: bikeReadPollIntervalSeconds
                ), let decoded = decodeTelemetry(packet) {
                    lastTelemetry = decoded
                    activeFTMS.sendTelemetry(decoded)
                }
            }

            let snapshotFTMS = activeFTMS
            let pairedOptions = webDeviceOptionsFromPairedDevices(
                selectedAddress: selectedBikeAddress,
                configuredAddress: bikeMacAddress
            )
            let nowForSnapshot = Date()
            if nowForSnapshot.timeIntervalSince(lastSnapshotAt) >= uiRefreshIntervalSeconds {
                webState.set(
                    WebDashboardSnapshot(
                        appVersion: appVersion,
                        status: webStatusLine,
                        isConnected: activeChannel != nil,
                        localWebURL: localWebURL,
                        lanWebURL: lanWebURL,
                        bikeTime: formatBikeTime(lastTelemetry),
                        bikeSpeed: formatBikeSpeed(lastTelemetry),
                        bikeCadence: formatBikeCadence(lastTelemetry),
                        bikePower: formatBikePower(lastTelemetry),
                        bikeResistance: formatBikeResistance(lastTelemetry),
                        bikeDistance: formatBikeDistance(lastTelemetry),
                        bikeCalories: formatBikeCalories(lastTelemetry),
                        bikeHeartRate: formatBikeHeartRate(lastTelemetry),
                        event: snapshotFTMS?.latestEvent ?? "disconnected",
                        source: snapshotFTMS?.latestResistanceSource ?? "-",
                        opcode: snapshotFTMS?.latestControlPointOpcodeHex ?? "-",
                        commandedResistance: snapshotFTMS?.currentCommandedResistanceLevel ?? stagedManualResistance,
                        autoBaseResistance: snapshotFTMS?.currentAutoBaseResistanceLevel ?? stagedAutoBaseResistance,
                        receivedGrade: formatSignedPercent(snapshotFTMS?.latestReceivedSimulationGradePercent),
                        appliedGrade: formatSignedPercent(snapshotFTMS?.latestSimulationGradePercent),
                        targetPower: formatWatts(snapshotFTMS?.latestTargetPowerWatts),
                        targetResistance: formatPercent(snapshotFTMS?.latestTargetResistancePercent),
                        tuning: tuning.snapshotString(),
                        selectedDeviceAddress: selectedBikeAddress,
                        deviceOptions: pairedOptions
                    )
                )
                lastSnapshotAt = nowForSnapshot
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: loopIdleSleepSeconds))
        }

        if let activeChannel {
            let stopResult = send(activeChannel, STOP)
            if stopResult != kIOReturnSuccess {
                printConnectionStatus("Stop signal failed.", lastPrinted: &lastConnectionStatusLine)
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            activeChannel.close()
            printConnectionStatus("Disconnected.", lastPrinted: &lastConnectionStatusLine)
        }

        func selfDrain() {
            activeChannel = nil
            activeRFCOMMDelegate = nil
            activeFTMS = nil
            lastTelemetry = nil
        }

        func formatBikeTime(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return String(format: "%02d:%02d:%02d", bike.hour, bike.minute, bike.second)
        }

        func formatBikeSpeed(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return String(format: "%.1f km/h", bike.speed)
        }

        func formatBikeCadence(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return "\(bike.rpm) RPM"
        }

        func formatBikePower(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return String(format: "%.1f W", bike.power)
        }

        func formatBikeResistance(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return "\(bike.resistance)"
        }

        func formatBikeDistance(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return String(format: "%.1f km", bike.distance)
        }

        func formatBikeCalories(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return "\(bike.calories) kcal"
        }

        func formatBikeHeartRate(_ bike: BikeTelemetry?) -> String {
            guard let bike else { return "-" }
            return "\(bike.heartRate) bpm"
        }

    }
}

func resolvePreferredBikeCandidates(selectedAddress: String?, allowBroadAutoDiscovery: Bool) -> [IOBluetoothDevice] {
    if let selectedAddress, !selectedAddress.isEmpty {
        guard let selected = IOBluetoothDevice(addressString: selectedAddress) else {
            return []
        }
        return [selected]
    }

    if !bikeMacAddress.isEmpty {
        guard let configured = IOBluetoothDevice(addressString: bikeMacAddress) else {
            return []
        }
        return [configured]
    }

    let candidates = autoDiscoverBikeCandidates(includeUnmatchedDevices: allowBroadAutoDiscovery)
    if allowBroadAutoDiscovery {
        return candidates
    }

    if candidates.count == 1 {
        return candidates
    }

    return []
}

func autoDiscoverBikeCandidates(includeUnmatchedDevices: Bool) -> [IOBluetoothDevice] {
    guard let pairedAny = IOBluetoothDevice.pairedDevices() else {
        return []
    }

    let pairedDevices = pairedAny.compactMap { $0 as? IOBluetoothDevice }
    if pairedDevices.isEmpty {
        return []
    }

    let prioritized = pairedDevices
        .sorted {
            ($0.nameOrAddress ?? "").localizedCaseInsensitiveCompare($1.nameOrAddress ?? "") == .orderedAscending
        }
        .sorted { lhs, rhs in
            scoreAutoDiscoveryCandidate(lhs) > scoreAutoDiscoveryCandidate(rhs)
        }

    if includeUnmatchedDevices {
        return prioritized
    }

    return prioritized.filter { scoreAutoDiscoveryCandidate($0) > 0 }
}

func webDeviceOptionsFromPairedDevices(selectedAddress: String?, configuredAddress: String) -> [WebDeviceOption] {
    let devices = autoDiscoverBikeCandidates(includeUnmatchedDevices: true)
        .sorted { lhs, rhs in
            let leftScore = webDevicePriorityScore(
                lhs,
                selectedAddress: selectedAddress,
                configuredAddress: configuredAddress
            )
            let rightScore = webDevicePriorityScore(
                rhs,
                selectedAddress: selectedAddress,
                configuredAddress: configuredAddress
            )
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return (lhs.nameOrAddress ?? "").localizedCaseInsensitiveCompare(rhs.nameOrAddress ?? "") == .orderedAscending
        }

    return devices.compactMap { device in
        guard let address = device.addressString, !address.isEmpty else {
            return nil
        }

        return WebDeviceOption(
            name: device.nameOrAddress ?? "unknown",
            address: address
        )
    }
}

func webDevicePriorityScore(
    _ device: IOBluetoothDevice,
    selectedAddress: String?,
    configuredAddress: String
) -> Int {
    let address = device.addressString ?? ""
    var score = scoreAutoDiscoveryCandidate(device) * 100

    if let selectedAddress, !selectedAddress.isEmpty, address.caseInsensitiveCompare(selectedAddress) == .orderedSame {
        score += 10_000
    }

    if !configuredAddress.isEmpty, address.caseInsensitiveCompare(configuredAddress) == .orderedSame {
        score += 9_000
    }

    return score
}

func printConnectionStatus(_ line: String, lastPrinted: inout String?) {
    guard line != lastPrinted else {
        return
    }
    print(line)
    lastPrinted = line
}

func printWebAccessInfo(port: UInt16) {
    let localhost = "127.0.0.1:\(port)"
    let lan = discoverHomeNetworkIPv4()

    print("Web interface:")
    print("- Local: http://\(localhost)")
    if let lan {
        print("- Home network: http://\(lan):\(port)")
    } else {
        print("- Home network: not detected")
    }
    print()
}

func discoverHomeNetworkIPv4() -> String? {
    var addresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
        return nil
    }
    defer { freeifaddrs(first) }

    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = current?.pointee {
        defer { current = ifa.ifa_next }
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }

        let flags = Int32(ifa.ifa_flags)
        let isUp = (flags & IFF_UP) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        guard isUp, !isLoopback else {
            continue
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameInfo = getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard nameInfo == 0 else {
            continue
        }

        let ip = String(cString: hostBuffer)
        addresses.append(ip)
    }

    if let private192 = addresses.first(where: { $0.hasPrefix("192.") }) {
        return private192
    }
    if let private10 = addresses.first(where: { $0.hasPrefix("10.") }) {
        return private10
    }
    if let private172 = addresses.first(where: { ip in
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let second = Int(parts[1]) else {
            return false
        }
        return ip.hasPrefix("172.") && (16...31).contains(second)
    }) {
        return private172
    }

    return nil
}

func scoreAutoDiscoveryCandidate(_ device: IOBluetoothDevice) -> Int {
    let searchText = [
        device.name ?? "",
        device.nameOrAddress ?? "",
        device.addressString ?? ""
    ]
    .joined(separator: " ")
    .lowercased()

    var score = 0
    if searchText.contains("iconsole") { score += 100 }
    if searchText.contains("abilica") { score += 90 }
    if searchText.contains("sb-x") { score += 80 }
    if searchText.contains("stream") { score += 70 }
    if searchText.contains("bike") { score += 20 }
    return score
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
