import Foundation
import IOBluetooth

// RFCOMM delegate, send helper, resistance packet and iConsole initialization

final class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {

    private var lastPacket: Data?
    private var receiveBuffer: [UInt8] = []

    private let lock = NSLock()

    func rfcommChannelData(
        _ channel: IOBluetoothRFCOMMChannel!,
        data pointer: UnsafeMutableRawPointer!,
        length: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard length > 0, let pointer else {
            return
        }

        let base = pointer.assumingMemoryBound(to: UInt8.self)
        receiveBuffer.append(contentsOf: UnsafeBufferPointer(start: base, count: length))

        // Stream parser: support fragmented and coalesced RFCOMM frames.
        while receiveBuffer.count >= 2 {
            var startIndex: Int?
            let scanLimit = receiveBuffer.count - 1
            for i in 0..<scanLimit where receiveBuffer[i] == 0xF0 && receiveBuffer[i + 1] == 0xB2 {
                startIndex = i
                break
            }

            guard let startIndex else {
                if receiveBuffer.last == 0xF0 {
                    receiveBuffer = [0xF0]
                } else {
                    receiveBuffer.removeAll(keepingCapacity: true)
                }
                break
            }

            if startIndex > 0 {
                receiveBuffer.removeFirst(startIndex)
            }

            guard receiveBuffer.count >= 21 else {
                break
            }

            lastPacket = Data(receiveBuffer.prefix(21))
            receiveBuffer.removeFirst(21)
        }

        if receiveBuffer.count > 2048 {
            if receiveBuffer.last == 0xF0 {
                receiveBuffer = [0xF0]
            } else {
                receiveBuffer = Array(receiveBuffer.suffix(64))
            }
        }
    }

    func takeLatestPacket() -> Data? {

        lock.lock()
        defer { lock.unlock() }

        let packet = lastPacket
        lastPacket = nil
        return packet
    }

    func rfcommChannelOpenComplete(
        _ channel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {

        print("RFCOMM open:", error)
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {

        print()
        print("RFCOMM closed")
    }

    func rfcommChannelWriteComplete(
        _ channel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {

        // Intentionally quiet.
    }
}


func send(_ channel: IOBluetoothRFCOMMChannel, _ bytes: [UInt8]) -> IOReturn {

    let data = Data(bytes)

    return data.withUnsafeBytes { buffer in

        guard let base = buffer.baseAddress else {
            return kIOReturnBadArgument
        }

        return channel.writeSync(
            UnsafeMutableRawPointer(mutating: base),
            length: UInt16(data.count)
        )
    }
}


func resistancePacket(level: Int) -> [UInt8] {

    let lvl = max(minResistanceLevel, min(maxResistanceLevel, level))

    let value = UInt8(lvl + 1)

    let checksum = UInt8((0xF0 + 0xA6 + 0x03 + lvl) & 0xFF)

    return [0xF0, 0xA6, 0x01, 0x01, value, checksum]
}


func setResistance(_ channel: IOBluetoothRFCOMMChannel, level: Int) {

    let lvl = max(minResistanceLevel, min(maxResistanceLevel, level))

    let packet = resistancePacket(level: lvl)

    let result = send(channel, packet)
    debugLog("BIKE RES CMD level=\(lvl) tx=\(packet.map { String(format: "%02X", $0) }.joined(separator: " ")) result=\(result)")
}


func initialize(_ channel: IOBluetoothRFCOMMChannel) -> Bool {

    let sequence: [[UInt8]] = [
        PING,
        INIT_A0,
        PING, PING, PING, PING, PING,
        STATUS,
        PING,
        INIT_A3,
        INIT_A4
    ]

    print()
    print("==============================================")
    print(" INITIALIZING iCONSOLE+")
    print("==============================================")

    for packet in sequence {

        let result = send(channel, packet)

        if result != kIOReturnSuccess {

            print("Initialization failed:", result)
            return false
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    print("Initialization complete")

    return true
}
