import SwiftUI

struct SerialConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = SerialConfiguration()
    @State private var ports: [String] = []
    @State private var showAdvanced = false
    @State private var errorMessage: String?

    let onConnect: (SerialConfiguration) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Serial Port").font(.title2.weight(.semibold))
                    Text("使用 macOS 內建 screen 連接本機序列裝置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新掃描", systemImage: "arrow.clockwise") { reloadPorts() }
            }

            Form {
                Picker("Serial Port", selection: $configuration.devicePath) {
                    Text("請選擇").tag("")
                    ForEach(ports, id: \.self) { Text($0).tag($0) }
                }
                Picker("Baud rate", selection: $configuration.baudRate) {
                    ForEach(SerialConfiguration.supportedBaudRates, id: \.self) { Text("\($0)").tag($0) }
                }

                DisclosureGroup("進階設定", isExpanded: $showAdvanced) {
                    Picker("Data bits", selection: $configuration.dataBits) {
                        ForEach([8, 7, 6, 5], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Stop bits", selection: $configuration.stopBits) {
                        Text("1").tag(1); Text("2").tag(2)
                    }
                    Picker("Parity", selection: $configuration.parity) {
                        ForEach(SerialParity.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Flow control", selection: $configuration.flowControl) {
                        ForEach(SerialFlowControl.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(ports.isEmpty ? "目前沒有偵測到 /dev/cu.* 裝置。" : "預設為常見的 9600 / 8-N-1 / 無 flow control。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("連線") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(configuration.devicePath.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 570, height: showAdvanced ? 500 : 340)
        .animation(.easeInOut(duration: 0.18), value: showAdvanced)
        .onAppear(perform: reloadPorts)
        .alert("無法連線 Serial Port", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知錯誤")
        }
    }

    private func reloadPorts() {
        ports = SerialPortCatalog.availablePorts()
        if !configuration.devicePath.isEmpty, !ports.contains(configuration.devicePath) {
            configuration.devicePath = ""
        }
    }

    private func connect() {
        do {
            try onConnect(configuration.validated())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
