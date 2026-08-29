import SwiftUI

struct AppInstancesView: View {
    let authManager: AuthManager

    @State private var instances: [ManagedAppInstance] = []
    @State private var creatingProvider: ServiceType = .cursor
    @State private var creatingName = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var launchingID: String?

    var body: some View {
        Form {
            Section {
                Text("Run several copies of the same app at once, each with its own profile and (optionally) a bound VibeRouter account. Same idea as Cockpit Tools multi-instance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("New instance") {
                Picker("App", selection: $creatingProvider) {
                    ForEach(AppInstanceManager.launchableProviders, id: \.rawValue) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                TextField("Name", text: $creatingName)
                    .textFieldStyle(.roundedBorder)
                Button("Create instance") {
                    let name = creatingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = name.isEmpty ? "\(creatingProvider.displayName) \(instances.count + 1)" : name
                    AppInstanceManager.upsert(.make(name: label, provider: creatingProvider))
                    creatingName = ""
                    reload()
                }
                .disabled(!AppInstanceManager.launchableProviders.contains(creatingProvider))
            }

            if instances.isEmpty {
                Section {
                    Text("No instances yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Instances") {
                    ForEach(instances) { instance in
                        instanceRow(instance)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? MenuBarDesign.danger : MenuBarDesign.success)
                }
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func instanceRow(_ instance: ManagedAppInstance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(.body.weight(.medium))
                    Text(instance.serviceType?.displayName ?? instance.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if launchingID == instance.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Start") {
                        Task { await launch(instance) }
                    }
                    .controlSize(.small)
                    Button("Stop") {
                        apply(AppInstanceManager.stop(instance))
                    }
                    .controlSize(.small)
                    Button("Delete", role: .destructive) {
                        AppInstanceManager.delete(instance)
                        reload()
                    }
                    .controlSize(.small)
                }
            }

            Picker("Bound account", selection: boundAccountBinding(instance)) {
                Text("None").tag(Optional<String>.none)
                ForEach(accounts(for: instance), id: \.id) { account in
                    Text(account.displayName).tag(Optional(account.id))
                }
            }

            Text(instance.userDataDir)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func boundAccountBinding(_ instance: ManagedAppInstance) -> Binding<String?> {
        Binding(
            get: { instance.boundAccountFile },
            set: { newValue in
                var updated = instance
                updated.boundAccountFile = newValue
                AppInstanceManager.upsert(updated)
                reload()
            }
        )
    }

    private func accounts(for instance: ManagedAppInstance) -> [AuthAccount] {
        guard let type = instance.serviceType else { return [] }
        return authManager.accounts(for: type)
    }

    private func launch(_ instance: ManagedAppInstance) async {
        launchingID = instance.id
        let result = await AppInstanceManager.launch(instance)
        launchingID = nil
        apply(result)
    }

    private func apply(_ result: AppInstanceLaunchResult) {
        switch result {
        case .launched(let message):
            statusIsError = false
            statusMessage = message
        case .failure(let message):
            statusIsError = true
            statusMessage = message
        }
    }

    private func reload() {
        instances = AppInstanceManager.load()
    }
}
