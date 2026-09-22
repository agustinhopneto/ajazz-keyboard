import Combine
import AppKit
import Foundation
import IOKit
import IOKit.hid
import ImageIO

enum AK820ImageFit: String, CaseIterable, Identifiable {
    case fill = "Preencher"
    case contain = "Mostrar tudo"
    case stretch = "Esticar"

    var id: Self { self }
}

struct AK820Device: Identifiable, Equatable {
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let transport: String

    var isControlInterface: Bool {
        // AK820 Pro firmware families expose their 64-byte configuration
        // channel as either FF13 (this wired board) or FF67.
        usagePage == 0xFF13 || usagePage == 0xFF67
    }

    var identifier: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

enum AK820HIDError: LocalizedError {
    case controlInterfaceNotFound
    case displayInterfaceNotFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case outputTimedOut
    case invalidGIF(String)

    var errorDescription: String? {
        switch self {
        case .controlInterfaceNotFound:
            "A interface de controle do AK820 Pro não foi encontrada. Conecte-o por cabo USB ou pelo receptor 2,4 GHz."
        case .displayInterfaceNotFound:
            "A interface HID de alta velocidade do visor não foi encontrada. Conecte o AK820 por cabo USB e atualize a conexão."
        case .openFailed(let result):
            "Não foi possível abrir a interface HID (erro \(result))."
        case .writeFailed(let result):
            "O teclado não aceitou o relatório de configuração (erro \(result))."
        case .outputTimedOut:
            "O teclado demorou demais para confirmar um bloco do GIF. Reconecte-o e tente novamente."
        case .invalidGIF(let reason):
            "Não foi possível preparar o GIF: \(reason)"
        }
    }
}

@MainActor
final class AK820HIDService: ObservableObject {
    @Published private(set) var devices: [AK820Device] = []
    @Published private(set) var lastError: String?
    @Published private(set) var clockSyncStatus: String?
    @Published private(set) var lightingStatus: String?
    @Published private(set) var gifStatus: String?
    @Published private(set) var selectedGIFURL: URL?
    @Published private(set) var isSendingGIF = false

    private let manager: IOHIDManager
    private var controlDevice: IOHIDDevice?
    private var displayDevice: IOHIDDevice?
    private var displayInputBuffer: UnsafeMutablePointer<UInt8>?
    private var pendingLighting: LightingRequest?
    private var lightingWorker: Task<Void, Never>?

    private struct LightingRequest {
        let effect: AK820Protocol.LightingEffect
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let rainbow: Bool
        let brightness: UInt8
        let speed: UInt8
        let direction: AK820Protocol.LightingDirection
    }

    private final class OutputReportRequest {
        let buffer: UnsafeMutablePointer<UInt8>
        let count: Int
        let continuation: CheckedContinuation<IOReturn, Never>

        init(packet: [UInt8], continuation: CheckedContinuation<IOReturn, Never>) {
            count = packet.count
            buffer = .allocate(capacity: packet.count)
            buffer.initialize(from: packet, count: packet.count)
            self.continuation = continuation
        }

        deinit {
            buffer.deinitialize(count: count)
            buffer.deallocate()
        }
    }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey as String: 0x0C45, kIOHIDProductIDKey as String: 0x8009],
            [kIOHIDProductIDKey as String: 0xFEFE]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            lastError = "O gerenciador HID não iniciou (erro \(result))."
        }
        refresh()
    }

    func refresh() {
        let rawDevices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        devices = rawDevices.map(makeDevice).sorted { $0.name < $1.name }
        controlDevice = rawDevices.first(where: isControlInterface)
        displayDevice = rawDevices.first(where: isDisplayInterface)

        if let displayDevice {
            configureDisplayInputDrain(for: displayDevice)
        }

        if controlDevice != nil {
            lastError = nil
        }
    }

    func selectGIF(_ url: URL) {
        selectedGIFURL = url
        gifStatus = nil
    }

    func importGIFFromPasteboard() {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        guard let url = urls?.first else {
            lastError = "Copie um arquivo GIF no Finder e tente novamente."
            return
        }
        guard url.pathExtension.lowercased() == "gif" else {
            lastError = "O item copiado não é um arquivo GIF."
            return
        }
        selectGIF(url)
        lastError = nil
    }

    /// Produces the same 128×128 centre-crop/contain/stretch raster used by
    /// the uploader. It deliberately previews the processed pixels, not the
    /// original GIF thumbnail.
    func previewGIF(from url: URL, fit: AK820ImageFit) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rendered = try? renderFrame(image, fit: fit) else {
            return nil
        }
        // Keep the preview in the same orientation as the pixels sent to the
        // vertically inverted AK820 panel.
        guard let preview = flipPreviewVertically(rendered.preview) else { return nil }
        return NSImage(cgImage: preview, size: NSSize(width: 128, height: 128))
    }

    /// Synchronizes only the time displayed on the keyboard. The four feature
    /// packets and their read-back cadence are hardware-verified for wired
    /// AK820 Pro firmware on the FF13 HID collection.
    func syncClock() async {
        do {
            guard let controlDevice else {
                throw AK820HIDError.controlInterfaceNotFound
            }
            let openResult = IOHIDDeviceOpen(controlDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess || openResult == kIOReturnExclusiveAccess else {
                throw AK820HIDError.openFailed(openResult)
            }

            let packets = [
                AK820Protocol.controlPacket(command: 0x18, byte8: 0x01),
                AK820Protocol.controlPacket(command: 0x28, byte8: 0x01),
                AK820Protocol.clockPacket(date: Date()),
                AK820Protocol.controlPacket(command: 0xF0, byte8: 0x01)
            ]

            for packet in packets {
                try writeFeature(packet, to: controlDevice)
                try? await Task.sleep(for: .milliseconds(35))
                readBackFeature(from: controlDevice)
            }

            let formatted = Date.now.formatted(date: .abbreviated, time: .shortened)
            clockSyncStatus = "Relógio sincronizado com \(formatted)."
            lastError = nil
        } catch {
            clockSyncStatus = nil
            lastError = error.localizedDescription
        }
    }

    /// Applies a lighting effect through the hardware-confirmed feature-report
    /// transaction. It does not touch key mappings or macros.
    func queueLighting(
        effect: AK820Protocol.LightingEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        rainbow: Bool,
        brightness: UInt8,
        speed: UInt8,
        direction: AK820Protocol.LightingDirection
    ) {
        pendingLighting = LightingRequest(
            effect: effect,
            red: red,
            green: green,
            blue: blue,
            rainbow: rainbow,
            brightness: brightness,
            speed: speed,
            direction: direction
        )
        guard lightingWorker == nil else { return }

        lightingWorker = Task { [weak self] in
            guard let self else { return }
            while let request = self.pendingLighting {
                self.pendingLighting = nil
                try? await Task.sleep(for: .milliseconds(180))
                // A newer click during the debounce replaces this request.
                if let newerRequest = self.pendingLighting {
                    self.pendingLighting = newerRequest
                    continue
                }
                await self.applyLighting(request)
            }
            self.lightingWorker = nil
        }
    }

    private func applyLighting(_ request: LightingRequest) async {
        do {
            guard let controlDevice else {
                throw AK820HIDError.controlInterfaceNotFound
            }
            let openResult = IOHIDDeviceOpen(controlDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess || openResult == kIOReturnExclusiveAccess else {
                throw AK820HIDError.openFailed(openResult)
            }

            let packets = [
                AK820Protocol.controlPacket(command: 0x18, byte8: 0x01),
                AK820Protocol.controlPacket(command: 0x13, byte8: 0x01),
                AK820Protocol.lightingPacket(
                    effect: request.effect,
                    red: request.red,
                    green: request.green,
                    blue: request.blue,
                    rainbow: request.rainbow,
                    brightness: request.brightness,
                    speed: request.speed,
                    direction: request.direction
                ),
                AK820Protocol.controlPacket(command: 0xF0, byte8: 0x01)
            ]

            for packet in packets {
                try writeFeature(packet, to: controlDevice)
                try? await Task.sleep(for: .milliseconds(35))
                readBackFeature(from: controlDevice)
            }

            lightingStatus = "\(request.effect.rawValue) aplicado: #\(String(format: "%02X%02X%02X", request.red, request.green, request.blue))."
            lastError = nil
        } catch {
            lightingStatus = nil
            lastError = error.localizedDescription
        }
    }

    /// Converts a GIF to the AK820's 128×128 RGB565 animation format and
    /// sends it as HID output reports to the dedicated large-report
    /// interface. This is intentionally separate from the FF13 lighting and
    /// clock feature-report channel.
    func uploadGIF(from url: URL, fit: AK820ImageFit) async {
        guard !isSendingGIF else { return }
        isSendingGIF = true
        defer { isSendingGIF = false }
        do {
            let animation = try prepareAnimation(from: url, fit: fit)
            try await transmitDisplayPayload(animation.payload, frameCount: animation.frameCount, label: "GIF")
            lastError = nil
        } catch {
            gifStatus = nil
            lastError = error.localizedDescription
        }
    }

    private func transmitDisplayPayload(_ payload: [UInt8], frameCount: Int, label: String) async throws {
        guard let controlDevice else {
            throw AK820HIDError.controlInterfaceNotFound
        }
        guard let displayDevice else {
            throw AK820HIDError.displayInterfaceNotFound
        }
        let openOptions = IOOptionBits(kIOHIDOptionsTypeNone)
        let controlOpenResult = IOHIDDeviceOpen(controlDevice, openOptions)
        guard controlOpenResult == kIOReturnSuccess || controlOpenResult == kIOReturnExclusiveAccess else {
            throw AK820HIDError.openFailed(controlOpenResult)
        }
        defer {
            IOHIDDeviceClose(controlDevice, openOptions)
        }

        // The official AJAZZ software prepares the display controller on the
        // 64-byte FF13 feature channel, writes the pixels on FF68, then sends
        // a final commit command. Sending pixels alone is accepted by macOS
        // but the keyboard deliberately leaves the current animation intact.
        try writeFeature(displayUploadPreparationPacket(), to: controlDevice)
        try? await Task.sleep(for: .milliseconds(40))
        readBackFeature(from: controlDevice)
        try writeFeature(displayUploadModePacket(), to: controlDevice)
        try? await Task.sleep(for: .milliseconds(40))
        readBackFeature(from: controlDevice)

        let reportLength = outputReportLength(for: displayDevice)
        guard reportLength >= 1024 else {
            throw AK820HIDError.displayInterfaceNotFound
        }
        let chunks = max(1, (payload.count + reportLength - 1) / reportLength)

        gifStatus = "Preparando \(frameCount) \(frameCount == 1 ? "quadro" : "quadros")…"
        let displayOpenResult = IOHIDDeviceOpen(displayDevice, openOptions)
        guard displayOpenResult == kIOReturnSuccess || displayOpenResult == kIOReturnExclusiveAccess else {
            throw AK820HIDError.openFailed(displayOpenResult)
        }
        for index in 0..<chunks {
            let start = index * reportLength
            let end = min(start + reportLength, payload.count)
            var report = Array(repeating: UInt8(0), count: reportLength)
            report.replaceSubrange(0..<(end - start), with: payload[start..<end])
            try await writeOutput(report, to: displayDevice)

            // Keep one continuous endpoint session, matching the official
            // utility. A slightly conservative cadence prevents the TFT
            // controller from stalling its on-screen loading indicator.
            try? await Task.sleep(for: .milliseconds(360))
            if (index + 1).isMultiple(of: 8) {
                try? await Task.sleep(for: .milliseconds(160))
            }

            if (index + 1).isMultiple(of: 4) || index == chunks - 1 {
                gifStatus = "Enviando \(label.lowercased())… \(Int(Double(index + 1) / Double(chunks) * 100))%"
                await Task.yield()
            }
        }

        IOHIDDeviceClose(displayDevice, openOptions)
        try writeFeature(displayUploadCommitPacket(), to: controlDevice)
        try? await Task.sleep(for: .milliseconds(40))
        readBackFeature(from: controlDevice)
        gifStatus = "\(label) concluído: \(frameCount) \(frameCount == 1 ? "quadro" : "quadros")."
    }

    /// First 64-byte feature report sent immediately before a display upload.
    /// This exact layout was observed on the wired AK820 Pro using the
    /// official AJAZZ Windows utility.
    private func displayUploadPreparationPacket() -> [UInt8] {
        var packet = Array(repeating: UInt8(0), count: AK820Protocol.reportLength)
        packet[0] = 0x04
        packet[1] = 0x18
        packet[3] = 0x01
        return packet
    }

    /// Selects the high-speed TFT upload mode. Byte 8 is the firmware token.
    private func displayUploadModePacket() -> [UInt8] {
        var packet = Array(repeating: UInt8(0), count: AK820Protocol.reportLength)
        packet[0] = 0x04
        packet[1] = 0x72
        packet[2] = 0x02
        packet[3] = 0x01
        packet[8] = 0xC9
        return packet
    }

    /// Finalises the upload so the new animation replaces the current visor
    /// content. Without this packet the keyboard preserves the old GIF.
    private func displayUploadCommitPacket() -> [UInt8] {
        var packet = Array(repeating: UInt8(0), count: AK820Protocol.reportLength)
        packet[0] = 0x04
        packet[1] = 0x02
        return packet
    }

    private func writeFeature(_ packet: [UInt8], to device: IOHIDDevice) throws {
        var report = packet
        let result = report.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, buffer.baseAddress!, buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw AK820HIDError.writeFailed(result)
        }
    }

    private func writeOutput(_ packet: [UInt8], to device: IOHIDDevice) async throws {
        let result: IOReturn = await withCheckedContinuation { continuation in
            let request = OutputReportRequest(packet: packet, continuation: continuation)
            let context = Unmanaged.passRetained(request).toOpaque()
            let startResult = IOHIDDeviceSetReportWithCallback(
                device,
                kIOHIDReportTypeOutput,
                0,
                request.buffer,
                request.count,
                2_000,
                Self.outputReportCallback,
                context
            )
            if startResult != kIOReturnSuccess {
                Unmanaged<OutputReportRequest>.fromOpaque(context).release()
                continuation.resume(returning: startResult)
            }
        }
        guard result == kIOReturnSuccess else {
            if result == kIOReturnTimeout {
                throw AK820HIDError.outputTimedOut
            }
            throw AK820HIDError.writeFailed(result)
        }
    }

    private func readBackFeature(from device: IOHIDDevice) {
        var report = Array(repeating: UInt8(0), count: AK820Protocol.reportLength)
        var length = report.count
        _ = report.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, buffer.baseAddress!, &length)
        }
    }

    /// The display interface emits short progress/status reports while large
    /// output reports are in flight. Keep its input endpoint drained, as the
    /// official utility does, so the firmware cannot fill that channel while
    /// rendering its Loading screen.
    private func configureDisplayInputDrain(for device: IOHIDDevice) {
        let reportLength = max(64, numberProperty(device, kIOHIDMaxInputReportSizeKey))
        if displayInputBuffer == nil {
            displayInputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        }
        guard let displayInputBuffer else { return }
        IOHIDDeviceRegisterInputReportCallback(
            device,
            displayInputBuffer,
            reportLength,
            Self.discardDisplayInputReport,
            nil
        )
    }

    private func makeDevice(_ device: IOHIDDevice) -> AK820Device {
        let name = stringProperty(device, kIOHIDProductKey) ?? "AJAZZ AK820 Pro"
        let vendorID = numberProperty(device, kIOHIDVendorIDKey)
        let productID = numberProperty(device, kIOHIDProductIDKey)
        let usagePage = numberProperty(device, kIOHIDPrimaryUsagePageKey)
        let transport = stringProperty(device, kIOHIDTransportKey) ?? "desconhecido"
        return AK820Device(
            id: "\(vendorID)-\(productID)-\(usagePage)-\(name)",
            name: name,
            vendorID: vendorID,
            productID: productID,
            usagePage: usagePage,
            transport: transport
        )
    }

    private func isControlInterface(_ device: IOHIDDevice) -> Bool {
        let page = numberProperty(device, kIOHIDPrimaryUsagePageKey)
        return page == 0xFF13 || page == 0xFF67
    }

    private func isDisplayInterface(_ device: IOHIDDevice) -> Bool {
        let page = numberProperty(device, kIOHIDPrimaryUsagePageKey)
        // Firmware variants expose the TFT collection on FF67 or FF68. Do
        // not use FF13 here: it is the 64-byte configuration channel.
        return (page == 0xFF67 || page == 0xFF68) && outputReportLength(for: device) >= 1024
    }

    private func outputReportLength(for device: IOHIDDevice) -> Int {
        // HID element sizes are not consistently expressed in the same unit
        // across the AK820's vendor collections. The device-level maximum is
        // the report length macOS expects for IOHIDDeviceSetReport.
        numberProperty(device, kIOHIDMaxOutputReportSizeKey)
    }

    private func prepareAnimation(from url: URL, fit: AK820ImageFit) throws -> (payload: [UInt8], frameCount: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AK820HIDError.invalidGIF("arquivo inválido")
        }
        let sourceCount = CGImageSourceGetCount(source)
        guard sourceCount > 0 else {
            throw AK820HIDError.invalidGIF("nenhum quadro encontrado")
        }

        let frameCount = min(sourceCount, 30)
        let frameIndexes = (0..<frameCount).map { index in
            sourceCount > frameCount ? index * sourceCount / frameCount : index
        }
        var header = Array(repeating: UInt8(0xFF), count: 256)
        header[0] = UInt8(frameCount)
        var frames: [[UInt8]] = []

        for (position, sourceIndex) in frameIndexes.enumerated() {
            guard let image = CGImageSourceCreateImageAtIndex(source, sourceIndex, nil) else {
                throw AK820HIDError.invalidGIF("não foi possível ler o quadro \(sourceIndex + 1)")
            }
            frames.append(try rgb565Pixels(for: image, fit: fit))
            header[position + 1] = frameDelay(from: source, at: sourceIndex)
        }
        return (header + frames.flatMap { $0 }, frameCount)
    }

    private func frameDelay(from source: CGImageSource, at index: Int) -> UInt8 {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gifProperties?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? 0.1
        return UInt8(max(8, min(255, Int((seconds * 200).rounded()))))
    }

    private func rgb565Pixels(for image: CGImage, fit: AK820ImageFit) throws -> [UInt8] {
        // The panel's USB coordinate system is vertically inverted. Flip
        // rows, but retain their left-to-right order.
        flipPixelsVertically(try renderFrame(image, fit: fit).rgb565)
    }

    private func flipPixelsVertically(_ pixels: [UInt8]) -> [UInt8] {
        var rotated = Array(repeating: UInt8(0), count: pixels.count)
        let bytesPerRow = 128 * 2
        for row in 0..<128 {
            let sourceStart = row * bytesPerRow
            let destinationStart = (127 - row) * bytesPerRow
            rotated.replaceSubrange(destinationStart..<(destinationStart + bytesPerRow),
                                    with: pixels[sourceStart..<(sourceStart + bytesPerRow)])
        }
        return rotated
    }

    private func flipPreviewVertically(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func renderFrame(_ image: CGImage, fit: AK820ImageFit) throws -> (rgb565: [UInt8], preview: CGImage) {
        let width = 128
        let height = 128
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        var rgba = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw AK820HIDError.invalidGIF("não foi possível preparar o quadro")
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
        let targetRect: CGRect
        switch fit {
        case .stretch:
            targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        case .fill:
            if sourceAspect > 1 {
                let scaledWidth = targetHeight * sourceAspect
                targetRect = CGRect(x: (targetWidth - scaledWidth) / 2, y: 0, width: scaledWidth, height: targetHeight)
            } else {
                let scaledHeight = targetWidth / sourceAspect
                targetRect = CGRect(x: 0, y: (targetHeight - scaledHeight) / 2, width: targetWidth, height: scaledHeight)
            }
        case .contain:
            if sourceAspect > 1 {
                let scaledHeight = targetWidth / sourceAspect
                targetRect = CGRect(x: 0, y: (targetHeight - scaledHeight) / 2, width: targetWidth, height: scaledHeight)
            } else {
                let scaledWidth = targetHeight * sourceAspect
                targetRect = CGRect(x: (targetWidth - scaledWidth) / 2, y: 0, width: scaledWidth, height: targetHeight)
            }
        }
        context.draw(image, in: targetRect)

        guard let preview = context.makeImage() else {
            throw AK820HIDError.invalidGIF("não foi possível criar a prévia")
        }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 2)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let value = (UInt16(rgba[offset] >> 3) << 11)
                | (UInt16(rgba[offset + 1] >> 2) << 5)
                | UInt16(rgba[offset + 2] >> 3)
            pixels.append(UInt8(value & 0xFF))
            pixels.append(UInt8(value >> 8))
        }
        return (pixels, preview)
    }

    private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    nonisolated private static let outputReportCallback: IOHIDReportCallback = { context, result, _, _, _, _, _ in
        guard let context else { return }
        let request = Unmanaged<OutputReportRequest>.fromOpaque(context).takeRetainedValue()
        request.continuation.resume(returning: result)
    }

    nonisolated private static let discardDisplayInputReport: IOHIDReportCallback = { _, _, _, _, _, _, _ in }

}
