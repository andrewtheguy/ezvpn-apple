import SwiftUI

struct ContentView: View {
    @StateObject private var vpn = VPNController()

    @State private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    // IPv4 split-tunnel routes (e.g. "10.0.0.0/8"). Empty = no IPv4 routing.
    @State private var routes = ""
    // IPv6 split-tunnel routes (e.g. the server's ULA prefix). Empty = no IPv6.
    @State private var routes6 = ""

    private var isConnecting: Bool {
        vpn.status == "connecting" || vpn.status == "reasserting"
    }

    private var isActive: Bool {
        vpn.status == "connected" || isConnecting || vpn.status == "disconnecting"
    }

    private var canConnect: Bool {
        !trimmed(serverNodeID).isEmpty
            && !trimmed(authToken).isEmpty
            && !isActive
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledField("Server node id") {
                        TextField("", text: $serverNodeID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Auth token") {
                        SecureField("", text: $authToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Relay URLs", hint: "comma-separated, optional") {
                        TextField("", text: $relayURLs)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section("Split tunnel (IPv4 private CIDRs)") {
                    LabeledField("IPv4 routes", hint: "comma-separated, optional") {
                        TextField("", text: $routes)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section("Split tunnel (IPv6 CIDRs)") {
                    LabeledField("IPv6 routes", hint: "comma-separated, optional") {
                        TextField("", text: $routes6)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section("Status") {
                    LabeledContent("State", value: vpn.status)
                    if let err = vpn.lastError {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    if isConnecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { vpn.disconnect() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else if isActive {
                        Button("Disconnect", role: .destructive) {
                            vpn.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        Button("Connect") {
                            Task { await vpn.connect(currentSettings()) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!canConnect)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("ezvpn")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func currentSettings() -> VPNController.Settings {
        VPNController.Settings(
            serverNodeID: trimmed(serverNodeID),
            authToken: trimmed(authToken),
            relayURLs: splitCSV(relayURLs),
            routes: splitCSV(routes),
            routes6: splitCSV(routes6)
        )
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// A form row whose label stays visible above the field even after the field
/// has content — unlike a placeholder, which disappears once the user types.
private struct LabeledField<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
