import SwiftUI

/// Edit the address, port, HTTPS flag, username, and password of a camera
/// that is already in the list. Reachable while the camera is disconnected
/// — the connection error and the sidebar menu both present it — so a bad
/// host or a camera that needs HTTPS is not a dead end.
///
/// Password is optional. Leaving it blank keeps the Keychain item. The
/// password is never written to `cameras.json` (AGENTS.md §4). Address,
/// port, username, and HTTPS are camera metadata and sync with the list.
public struct EditConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    let entry: CameraEntry

    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String = ""
    @State private var useHTTPS: Bool
    @State private var fieldErrors: [CameraEntryDraft.Field: String] = [:]
    @State private var didLoad = false

    public init(entry: CameraEntry) {
        self.entry = entry
        _host = State(initialValue: entry.host)
        _port = State(initialValue: String(entry.port))
        _username = State(initialValue: entry.username)
        _useHTTPS = State(initialValue: entry.useHTTPS)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Name", value: entry.displayName)
                }
                Section("Connection") {
                    TextField("Host or IP", text: $host)
                        .onChange(of: host) { _, _ in fieldErrors[.host] = nil }
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    fieldError(.host)
                    TextField("Port", text: $port)
                        .onChange(of: port) { _, _ in fieldErrors[.port] = nil }
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                    fieldError(.port)
                    Toggle("Use HTTPS", isOn: $useHTTPS)
                        .onChange(of: useHTTPS) { _, enabled in
                            if enabled, port == "80" { port = "443" }
                            if !enabled, port == "443" { port = "80" }
                        }
                    Text("Turn this on when the camera redirects its web page to a secure connection. DomusCam pins that certificate the same way as any other HTTPS camera.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Credentials") {
                    TextField("Username", text: $username)
                        .onChange(of: username) { _, _ in fieldErrors[.username] = nil }
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    fieldError(.username)
                    SecureField("Password", text: $password, prompt: Text("Leave blank to keep the saved password"))
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .accessibilityLabel("Password")
                        .accessibilityHint("Leave blank to keep the saved password")
                }
                Section {
                    Text("The password stays in this device's Keychain. The address, port, and HTTPS setting sync with the camera list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Connection")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: submit)
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                reloadFromStore()
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private func fieldError(_ field: CameraEntryDraft.Field) -> some View {
        if let message = fieldErrors[field] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(message)
        }
    }

    private func reloadFromStore() {
        guard let latest = store.cameras.first(where: { $0.id == entry.id }) else { return }
        host = latest.host
        port = String(latest.port)
        username = latest.username
        useHTTPS = latest.useHTTPS
    }

    private func submit() {
        switch store.updateConnection(
            host: host,
            port: port,
            username: username,
            useHTTPS: useHTTPS,
            password: password,
            for: entry.id
        ) {
        case .saved, .passwordRejected, .missingCamera:
            dismiss()
        case .invalid(let errors):
            fieldErrors = errors
        }
    }
}
