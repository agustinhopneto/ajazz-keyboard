import Foundation

/// AJAZZ AK820 Pro's vendor HID protocol.
///
/// Packets are 64-byte output reports. The payload format is intentionally kept
/// separate from the HID transport so write commands can be added only after
/// being tested against a physical keyboard.
enum AK820Protocol {
    static let reportLength = 64

    /// A 64-byte feature-report payload for the wired AK820 Pro's FF13
    /// collection. `0x04` belongs in byte zero of the payload; the macOS
    /// IOHID API sends HID report ID `0` separately.
    static func controlPacket(command: UInt8, byte2: UInt8 = 0, byte8: UInt8 = 0) -> [UInt8] {
        var packet = Array(repeating: UInt8(0), count: reportLength)
        packet[0] = 0x04
        packet[1] = command
        packet[2] = byte2
        packet[8] = byte8
        return packet
    }

    static func clockPacket(date: Date, calendar: Calendar = .current) -> [UInt8] {
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var packet = Array(repeating: UInt8(0), count: reportLength)
        packet[0] = 0x00
        packet[1] = 0x01
        packet[2] = 0x5A
        packet[3] = UInt8((fields.year ?? 2000) - 2000)
        packet[4] = UInt8(fields.month ?? 1)
        packet[5] = UInt8(fields.day ?? 1)
        packet[6] = UInt8(fields.hour ?? 0)
        packet[7] = UInt8(fields.minute ?? 0)
        packet[8] = UInt8(fields.second ?? 0)
        packet[10] = UInt8((fields.year ?? 2000) % 100)
        packet[62] = 0xAA
        packet[63] = 0x55
        return packet
    }

    enum LightingEffect: String, CaseIterable, Identifiable {
        case staticColor = "Cor estática"
        case breathing = "Respiração"
        case spectrum = "Espectro"
        case falling = "Chuva"
        case scrolling = "Deslizamento"
        case rolling = "Rolagem"
        case ripples = "Ondas"
        case flowing = "Fluxo"
        case pulsating = "Pulsação"

        var id: String { rawValue }

        var firmwareCode: UInt8 {
            switch self {
            case .staticColor: 0x01
            case .breathing: 0x07
            case .spectrum: 0x08
            case .falling: 0x05
            case .scrolling: 0x0A
            case .rolling: 0x0B
            case .ripples: 0x0F
            case .flowing: 0x10
            case .pulsating: 0x11
            }
        }

        var supportsDirection: Bool {
            self == .scrolling || self == .rolling || self == .flowing
        }
    }

    enum LightingDirection: String, CaseIterable, Identifiable {
        case left = "Esquerda"
        case down = "Baixo"
        case up = "Cima"
        case right = "Direita"

        var id: String { rawValue }
        var firmwareCode: UInt8 {
            switch self {
            case .left: 0
            case .down: 1
            case .up: 2
            case .right: 3
            }
        }
    }

    static func lightingPacket(
        effect: LightingEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        rainbow: Bool,
        brightness: UInt8,
        speed: UInt8,
        direction: LightingDirection
    ) -> [UInt8] {
        var packet = Array(repeating: UInt8(0), count: reportLength)
        packet[0] = effect.firmwareCode
        packet[1] = red
        packet[2] = green
        packet[3] = blue
        packet[8] = rainbow ? 1 : 0
        packet[9] = min(brightness, 5)
        packet[10] = effect == .staticColor ? 0 : min(speed, 5)
        packet[11] = direction.firmwareCode
        packet[14] = 0x55
        packet[15] = 0xAA
        return packet
    }

}
