import Foundation

// Telemetry model and decoder

struct BikeTelemetry {

    let hour: Int
    let minute: Int
    let second: Int

    let speed: Double
    let rpm: Int
    let distance: Double
    let calories: Int
    let heartRate: Int
    let power: Double
    let resistance: Int
}


func decodeTelemetry(
    _ data: Data
) -> BikeTelemetry? {
    guard data.count == 21 else {
        return nil
    }

    guard data[data.startIndex] == 0xF0,
          data[data.startIndex + 1] == 0xB2 else {
        return nil
    }

    func byte(_ offset: Int) -> Int {
        Int(data[data.startIndex + offset])
    }


    let hour =
        max(0, byte(2) - 1)

    let minute =
        max(0, byte(3) - 1)

    let second =
        max(0, byte(4) - 1)


    let speedRaw =
        100 * (byte(6) - 1) +
        (byte(7) - 1)

    let speed =
        Double(speedRaw) / 10.0


    let rpm =
        100 * (byte(8) - 1) +
        (byte(9) - 1)


    let distanceRaw =
        100 * (byte(10) - 1) +
        (byte(11) - 1)

    let distance =
        Double(distanceRaw) / 10.0


    let calories =
        100 * (byte(12) - 1) +
        (byte(13) - 1)


    let heartRate =
        100 * (byte(14) - 1) +
        (byte(15) - 1)


    let powerRaw =
        100 * (byte(16) - 1) +
        (byte(17) - 1)

    let power =
        Double(powerRaw) / 10.0


    let resistance =
        byte(18) - 1


    return BikeTelemetry(
        hour: hour,
        minute: minute,
        second: second,
        speed: speed,
        rpm: rpm,
        distance: distance,
        calories: calories,
        heartRate: heartRate,
        power: power,
        resistance: resistance
    )
}
