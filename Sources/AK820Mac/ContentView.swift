import AppKit
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @ObservedObject var hid: AK820HIDService

    @State private var effect = AK820Protocol.LightingEffect.staticColor
    @State private var direction = AK820Protocol.LightingDirection.left
    @State private var red = 0.0
    @State private var green = 0.68
    @State private var blue = 0.95
    @State private var rainbow = false
    @State private var brightness = 5.0
    @State private var speed = 3.0
    @State private var selectedSection = Section.color
    @State private var imageFit = AK820ImageFit.fill
    @State private var gifPreview: AK820GIFPreview?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var startupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Ajazz Keyboard", systemImage: "keyboard").font(.headline)
                Spacer()
                connectionBadge
                Button { hid.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Atualizar conexão")
                .accessibilityLabel("Atualizar conexão")
                .disabled(hid.isSendingGIF)
            }
            Divider()

            Picker("Seção", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(hid.isSendingGIF)

            Group {
                switch selectedSection {
                case .color: colorTab
                case .gif: gifTab
                case .clock: clockTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)

            communicationStatus

            Toggle("Abrir ao iniciar o Mac", isOn: $launchAtLogin)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
                .disabled(hid.isSendingGIF)

            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 5) {
                        Text("⌘Q")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("Encerrar")
                    }
                }
                .keyboardShortcut("q", modifiers: .command)
                .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .onChange(of: effect) { _, _ in queueLightingUpdate() }
        .onChange(of: direction) { _, _ in queueLightingUpdate() }
        .onChange(of: rainbow) { _, _ in queueLightingUpdate() }
        .onChange(of: red) { _, _ in queueLightingUpdate() }
        .onChange(of: green) { _, _ in queueLightingUpdate() }
        .onChange(of: blue) { _, _ in queueLightingUpdate() }
        .onChange(of: brightness) { _, _ in queueLightingUpdate() }
        .onChange(of: speed) { _, _ in queueLightingUpdate() }
        .onChange(of: hid.selectedGIFURL) { _, _ in refreshGIFPreview() }
        .onChange(of: imageFit) { _, _ in refreshGIFPreview() }
        .onAppear { refreshGIFPreview() }
    }

    private var colorTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Efeito", selection: $effect) {
                    ForEach(AK820Protocol.LightingEffect.allCases) { effect in
                        Text(effect.rawValue).tag(effect)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Cores RGB", isOn: $rainbow)

                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: red, green: green, blue: blue))
                        .frame(width: 38, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.22)))
                    Text("#\(hexColor)").font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("Brilho \(Int(brightness))/5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    ForEach(presets) { preset in
                        Button {
                            red = preset.red
                            green = preset.green
                            blue = preset.blue
                        } label: {
                            Circle()
                                .fill(Color(red: preset.red, green: preset.green, blue: preset.blue))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                        .disabled(rainbow)
                        .accessibilityLabel(preset.name)
                    }
                }
                .opacity(rainbow ? 0.45 : 1)

                DisclosureGroup("Cor personalizada") {
                    VStack(spacing: 7) {
                        colorSlider("Vermelho", value: $red, tint: .red)
                        colorSlider("Verde", value: $green, tint: .green)
                        colorSlider("Azul", value: $blue, tint: .blue)
                    }
                    .padding(.top, 5)
                    .disabled(rainbow)
                    .opacity(rainbow ? 0.45 : 1)
                }

                controlSlider(
                    symbol: "sun.max.fill",
                    label: "Brilho",
                    value: $brightness,
                    tint: .yellow
                )
                if effect != .staticColor {
                    controlSlider(
                        symbol: "bolt.fill",
                        label: "Velocidade",
                        value: $speed,
                        tint: .cyan
                    )
                }
                if effect.supportsDirection {
                    Picker("Direção", selection: $direction) {
                        ForEach(AK820Protocol.LightingDirection.allCases) { direction in
                            Text(direction.rawValue).tag(direction)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .disabled(!isConnected || hid.isSendingGIF)
        }
    }

    private var clockTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Relógio do teclado", systemImage: "clock.fill")
                .font(.headline)
            Text("Ajusta o relógio exibido no AK820 para a hora atual do Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sincronizar agora") { Task { await hid.syncClock() } }
                .disabled(!isConnected || hid.isSendingGIF)
            Spacer()
        }
    }

    private var gifTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GIF do visor")
                .font(.headline)
            Text("No Finder, selecione o GIF e pressione ⌘C. Depois cole-o aqui.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Group {
                    if let gifPreview {
                        AnimatedGIFPreview(animation: gifPreview)
                            .id(gifPreview.id)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 7) {
                    Text(hid.selectedGIFURL?.lastPathComponent ?? "Nenhum GIF selecionado")
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    Button("Colar GIF do Finder") { hid.importGIFFromPasteboard() }
                    Text("Prévia animada: 25 quadros · 128 × 128")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Ajuste", selection: $imageFit) {
                ForEach(AK820ImageFit.allCases) { fit in
                    Text(fit.rawValue).tag(fit)
                }
            }
            .pickerStyle(.segmented)

            Text("A prévia reproduz os 25 quadros normalizados, com a mesma orientação e tempos enviados ao teclado.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    guard let url = hid.selectedGIFURL else { return }
                    Task { await hid.uploadGIF(from: url, fit: imageFit) }
                } label: {
                    Label("Enviar ao teclado", systemImage: "arrow.up.doc")
                }
                .disabled(hid.selectedGIFURL == nil || !isConnected || hid.isSendingGIF)

            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var communicationStatus: some View {
        if let status = hid.lightingStatus {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(1)
        }
        if let error = hid.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
        if let status = hid.gifStatus {
            Label(status, systemImage: "photo.on.rectangle.angled")
                .font(.caption).foregroundStyle(.green).lineLimit(1)
        }
        if hid.isSendingGIF {
            Text("Envio em andamento — controles temporariamente bloqueados.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let startupError {
            Label(startupError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var isConnected: Bool { hid.devices.contains(where: \.isControlInterface) }

    private var connectionBadge: some View {
        Label(isConnected ? "Conectado" : "Desconectado", systemImage: isConnected ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isConnected ? .green : .secondary)
    }

    private func queueLightingUpdate() {
        guard isConnected, !hid.isSendingGIF else { return }
        hid.queueLighting(
            effect: effect,
            red: UInt8((red * 255).rounded()),
            green: UInt8((green * 255).rounded()),
            blue: UInt8((blue * 255).rounded()),
            rainbow: rainbow,
            brightness: UInt8(brightness),
            speed: UInt8(speed),
            direction: direction
        )
    }

    private func refreshGIFPreview() {
        guard let url = hid.selectedGIFURL else {
            gifPreview = nil
            return
        }
        gifPreview = hid.previewAnimation(from: url, fit: imageFit)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startupError = nil
        } catch {
            launchAtLogin = false
            startupError = "Não foi possível alterar a inicialização automática: \(error.localizedDescription)"
        }
    }

    private func colorSlider(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 66, alignment: .leading)
            Slider(value: value, in: 0...1).tint(tint)
            Text("\(Int(value.wrappedValue * 255))")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func controlSlider(
        symbol: String,
        label: String,
        value: Binding<Double>,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(tint)
                .accessibilityLabel(label)
            Slider(value: value, in: 0...5, step: 1)
                .tint(tint)
            Text("\(Int(value.wrappedValue))/5")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var hexColor: String {
        String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    private enum Section: String, CaseIterable, Identifiable {
        case color = "Cor"
        case gif = "GIF"
        case clock = "Relógio"

        var id: Self { self }
    }

    private var presets: [ColorPreset] {
        [
            .init(name: "Ciano", red: 0.0, green: 0.68, blue: 0.95),
            .init(name: "Roxo", red: 0.55, green: 0.25, blue: 0.95),
            .init(name: "Rosa", red: 1.0, green: 0.18, blue: 0.58),
            .init(name: "Vermelho", red: 1.0, green: 0.15, blue: 0.15),
            .init(name: "Laranja", red: 1.0, green: 0.48, blue: 0.08),
            .init(name: "Verde", red: 0.12, green: 0.9, blue: 0.42),
            .init(name: "Branco", red: 1.0, green: 1.0, blue: 1.0)
        ]
    }
}

private struct AnimatedGIFPreview: View {
    let animation: AK820GIFPreview

    @State private var frameIndex = 0
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        Image(nsImage: animation.frames[frameIndex])
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .onAppear { startPlayback() }
            .onDisappear { playbackTask?.cancel() }
    }

    private func startPlayback() {
        playbackTask?.cancel()
        frameIndex = 0
        playbackTask = Task { @MainActor [animation] in
            while !Task.isCancelled {
                let delay = max(animation.frameDelays[frameIndex], 0.04)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                frameIndex = (frameIndex + 1) % animation.frames.count
            }
        }
    }
}

private struct ColorPreset: Identifiable {
    let name: String
    let red: Double
    let green: Double
    let blue: Double
    var id: String { name }
}
