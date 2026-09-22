import AppKit
import LokiCore
import SwiftUI

private enum Palette {
    static let accent = Color.accentColor
    static let healthy = Color.green
}

// Keep native glass availability and the older macOS appearance in one place.
private struct PrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct SecondaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct FooterGlass: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(prominent ? Palette.accent : nil).interactive(), in: Capsule())
        } else if prominent {
            content.background(Palette.accent, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    var iconOnly = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: iconOnly ? 16 : 13, weight: .medium))
            .padding(.horizontal, iconOnly ? 0 : 16)
            .frame(width: iconOnly ? 32 : nil, height: 32)
            .foregroundStyle(iconOnly ? Color.primary : .white)
            .contentShape(Capsule())
            .modifier(FooterGlass(prominent: !iconOnly))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var adding = false
    @State private var editing: Forward?
    @State private var contentHeight: CGFloat = 140

    var body: some View {
        Group {
            if adding || editing != nil {
                ForwardEditor(model: model, existing: editing) {
                    adding = false
                    editing = nil
                }
            } else {
                dashboard
            }
        }
        .frame(width: 480)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else {
                WindowMaterial().ignoresSafeArea()
            }
        }
        .tint(Palette.accent)
        .alert("Loki needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 42, height: 42)
                    .background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Loki").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(connectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(model.needsAttention ? Color.orange : Color.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 20)
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No forwards", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Forward a port from an SSH host to this Mac.")
                } actions: {
                    Button("Add Forward") { adding = true }
                        .modifier(PrimaryActionStyle())
                }
                .frame(height: 210)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.hosts, id: \.self) { host in
                            let forwards = model.configuration.forwards.filter { $0.host == host }
                            let enabledCount = forwards.filter(\.enabled).count
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                                    Text(host).font(.subheadline.weight(.semibold)).lineLimit(1).help(host)
                                    Spacer()
                                    if enabledCount > 0 && enabledCount < forwards.count {
                                        Text("\(enabledCount) of \(forwards.count) on")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button { model.reconnect(host: host) } label: {
                                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                                    }.buttonStyle(.plain).help("Reconnect \(host)").accessibilityLabel("Reconnect \(host)")
                                        .disabled(enabledCount == 0)
                                    Toggle("Forward ports on \(host)", isOn: Binding(
                                        get: { enabledCount == forwards.count },
                                        set: { model.setAllEnabled($0, host: host) }))
                                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                                        .help(enabledCount == forwards.count ? "Pause all forwards on \(host)" : "Enable all forwards on \(host)")
                                }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                                VStack(spacing: 0) {
                                    let sessions = model.sessions.filter { $0.forward.host == host }
                                    ForEach(sessions) { session in
                                        ForwardRow(session: session, toggle: { model.toggle(session) },
                                                   edit: { editing = session.forward },
                                                   stopRemoteProcess: { model.stopRemoteProcess(session, force: $0) },
                                                   remove: { model.remove(session.id) })
                                    }
                                }.padding(6)
                            }
                            .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.65),
                                        in: RoundedRectangle(cornerRadius: 18))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                            }
                        }
                    }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, 440))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)

            }
            HStack(spacing: 16) {
                Button { adding = true } label: {
                    Label("Add Forward", systemImage: "plus")
                }
                .buttonStyle(FooterButtonStyle())
                .keyboardShortcut("n")
                Spacer()
                Menu {
                    Button(model.enabledCount > 0 ? "Pause All Forwards" : "Resume All Forwards") {
                        model.setAllEnabled(model.enabledCount == 0)
                    }
                    Button("Refresh Project Details") { model.refreshDiscovery() }
                    Divider()
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                    Toggle("Notify about sustained outages", isOn: Binding(
                        get: { model.configuration.notifyOnOutage }, set: { model.setNotifications($0) }))
                    Divider()
                    Button("Quit Loki") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(FooterButtonStyle(iconOnly: true))
                    .help("Settings").accessibilityLabel("Settings")
            }
            .controlSize(.large)
            .padding(16)
        }
    }

    private var connectionSummary: String {
        if model.sessions.isEmpty { return "SSH port forwarding" }
        if model.enabledCount == 0 { return "All forwards paused" }
        return "\(model.connectedCount) of \(model.enabledCount) connected"
    }
}

private struct ForwardRow: View {
    @ObservedObject var session: TunnelSession
    let toggle: () -> Void
    let edit: () -> Void
    let stopRemoteProcess: (Bool) -> Void
    let remove: () -> Void
    @State private var expanded = false
    @State private var confirmingRemoval = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var forward: Forward { session.forward }
    private var status: ForwardStatus { session.status }
    private var name: String {
        return status.processes.first?.projectName ?? "Port \(forward.localPort)"
    }
    private var color: Color {
        if status.needsAttention { return .orange }
        if status.connection == .connected {
            if case .responding = status.service { return Palette.healthy }
            return Palette.accent
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        Circle().fill(color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(name).font(.body.weight(.semibold)).lineLimit(1)
                                    .layoutPriority(1)
                                if let process = status.processes.first, !process.branch.isEmpty {
                                    Label(process.branch, systemImage: "arrow.triangle.branch")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary).lineLimit(1)
                                        .help(process.branch)
                                }
                            }
                            HStack(spacing: 5) {
                                Text(session.isStoppingRemoteProcess ? "Stopping remote process…" : status.title).lineLimit(1)
                                if status.metadataError != nil {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .help("Project details could not be refreshed")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(status.needsAttention ? Color.orange : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(forward.localPort))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                            .fixedSize()
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name), local port \(String(forward.localPort)), \(status.title)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("\(expanded ? "Hide" : "Show") forward details")
                if let url = forward.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(url.absoluteString)")
                    .accessibilityLabel("Open port \(String(forward.localPort)) in browser")
                    .disabled(status.connection != .connected)
                }
                Toggle("Forward port \(String(forward.localPort))", isOn: Binding(
                    get: { forward.enabled },
                    set: { if $0 != forward.enabled { toggle() } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help(forward.enabled ? "Pause this forward" : "Resume this forward")
            }
            .padding(.horizontal, 10)
            if expanded { details.padding(.leading, 37).padding(.trailing, 12).padding(.bottom, 12) }
        }
        .background(hovered || expanded ? Color.primary.opacity(0.045) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Edit forward", action: edit)
            Button(forward.enabled ? "Pause" : "Resume", action: toggle)
            Button("Reconnect") { session.restart() }.disabled(!forward.enabled)
            Button("Copy address", action: copyAddress)
            Divider()
            Button(session.isStoppingRemoteProcess ? "Stopping remote process…" : "Stop remote process", role: .destructive) {
                stopRemoteProcess(false)
            }.disabled(session.isStoppingRemoteProcess)
            if session.canForceStopRemoteProcess {
                Button("Force stop remote process", role: .destructive) { stopRemoteProcess(true) }
                    .disabled(session.isStoppingRemoteProcess)
            }
            Divider()
            Button("Remove Forward…", role: .destructive) { confirmingRemoval = true }
        }
        .confirmationDialog("Remove this forward?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Forward", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops forwarding local port \(String(forward.localPort)). You can add it again later.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("localhost:\(String(forward.localPort)) → \(forward.host):\(String(forward.remotePort))")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if case .retrying(let date) = status.connection {
                Text("Retrying \(date, style: .relative)").font(.caption).foregroundStyle(.secondary)
            }
            if let error = status.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            ForEach(Array(status.processes.enumerated()), id: \.offset) { _, process in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(process.command) · PID \(String(process.pid))").lineLimit(2)
                    Text(process.directory).textSelection(.enabled)
                    if !process.branch.isEmpty { Text("Branch: \(process.branch)") }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let date = status.metadataCheckedAt {
                Text("Project details checked \(date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
            }
            if let error = status.metadataError {
                Text("Project details unavailable: \(error)").font(.caption2).foregroundStyle(.orange).lineLimit(4)
            }
            if let date = status.lastResponseAt {
                Text("Last HTTP response \(date, style: .time)").font(.caption2).foregroundStyle(.secondary)
            }
            if forward.probe == .tcp {
                Text("TCP mode does not check application responses.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(forward.enabled ? "Pause" : "Resume", action: toggle)
                Button("Reconnect") { session.restart() }.disabled(!forward.enabled)
                Button("Copy address", action: copyAddress)
                Spacer()
                Button("Edit", action: edit)
            }.controlSize(.small).buttonStyle(.bordered)
            if !status.events.isEmpty {
                DisclosureGroup("Recent activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.events.suffix(8).reversed()) { event in
                            HStack(alignment: .top) {
                                Text(event.date, style: .time).foregroundStyle(.tertiary)
                                Text(event.message).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 10)).textSelection(.enabled)
                        }
                    }.padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(forward.url?.absoluteString ?? "127.0.0.1:\(forward.localPort)", forType: .string)
    }
}

private struct ForwardEditor: View {
    @ObservedObject var model: AppModel
    let existing: Forward?
    let dismiss: () -> Void
    @State private var host: String
    @State private var localPorts: String
    @State private var isRange = false
    @State private var localEnd = "3019"
    @State private var sameRemotePorts: Bool
    @State private var remotePort: String
    @State private var probe: ProbeMode
    @State private var enabled: Bool
    @State private var error: String?
    @State private var confirmingRemoval = false
    @FocusState private var hostFocused: Bool

    init(model: AppModel, existing: Forward?, dismiss: @escaping () -> Void) {
        self.model = model
        self.existing = existing
        self.dismiss = dismiss
        _host = State(initialValue: existing?.host ?? model.hosts.first ?? "")
        _localPorts = State(initialValue: existing.map { String($0.localPort) } ?? "3010")
        _sameRemotePorts = State(initialValue: existing.map { $0.localPort == $0.remotePort } ?? true)
        _remotePort = State(initialValue: existing.map { String($0.remotePort) } ?? "3010")
        _probe = State(initialValue: existing?.probe ?? .http)
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "Add Forward" : "Edit Forward")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
            Form {
                Section {
                    TextField("SSH host", text: $host, prompt: Text("Host or SSH alias"))
                        .focused($hostFocused)
                } footer: {
                    Text("Connects using your SSH configuration and keys.")
                }
                Section {
                    if existing == nil {
                        Picker("Forward", selection: $isRange) {
                            Text("Single port").tag(false)
                            Text("Port range").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    TextField(isRange ? "Local start" : "Local port", text: $localPorts, prompt: Text("3010"))
                    if isRange {
                        TextField("Local end", text: $localEnd, prompt: Text("3019"))
                    }
                    Toggle("Use matching remote ports", isOn: $sameRemotePorts)
                    if !sameRemotePorts {
                        TextField(isRange ? "Remote start" : "Remote port", text: $remotePort, prompt: Text("3010"))
                    }
                } header: {
                    Text("Ports")
                } footer: {
                    if let ports = try? parsedPorts() {
                        Text(mappingPreview(ports))
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Picker("Service check", selection: $probe) {
                        ForEach(ProbeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Connect automatically", isOn: $enabled)
                } footer: {
                    Text("Forwarded ports are only accessible on this Mac.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: (isRange ? 50 : 0) + (sameRemotePorts ? 0 : 50) + 430)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            HStack {
                if existing != nil {
                    Button("Remove…", role: .destructive) { confirmingRemoval = true }
                }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    .modifier(SecondaryActionStyle())
                Button(saveTitle, action: save).keyboardShortcut(.defaultAction)
                    .modifier(PrimaryActionStyle())
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 8)
        }
        .frame(width: 480)
        .onAppear { hostFocused = existing == nil }
        .confirmationDialog("Remove this forward?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Forward", role: .destructive) {
                guard let existing else { return }
                do {
                    try model.upsert([], replacing: existing.id)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops forwarding local port \(String(existing?.localPort ?? 0)). You can add it again later.")
        }
    }

    private func save() {
        do {
            let ports = try parsedPorts()
            let forwards = ports.local.map { port in
                Forward(id: existing?.id ?? UUID(), host: host.trimmingCharacters(in: .whitespaces),
                        localPort: port, remotePort: ports.remoteStart + port - ports.local.lowerBound,
                        probe: probe, enabled: enabled)
            }
            try model.upsert(forwards, replacing: existing?.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private var saveTitle: String {
        if existing != nil { return "Save Changes" }
        guard let ports = try? parsedPorts() else { return "Add Forward" }
        return ports.local.count == 1 ? "Add Forward" : "Add \(ports.local.count) Forwards"
    }

    private func parsedPorts() throws -> (local: ClosedRange<Int>, remoteStart: Int) {
        // Keep pasted ranges working alongside the explicit start/end fields.
        let input = isRange ? "\(localPorts)-\(localEnd)" : localPorts
        let parts = input.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...2).contains(parts.count), let first = Int(parts[0]),
              let last = parts.count == 2 ? Int(parts[1]) : first else {
            throw ConfigurationError.invalid("Enter valid ports, such as 3010 through 3019.")
        }
        guard (1024...65535).contains(first), (1024...65535).contains(last) else {
            throw ConfigurationError.invalid("Local ports must be 1024–65535.")
        }
        guard last >= first, last - first < 100, existing == nil || first == last else {
            throw ConfigurationError.invalid("Use an ascending range of up to 100 ports. Edit existing forwards individually.")
        }
        guard let start = sameRemotePorts ? first : Int(remotePort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(start), start <= 65535 - (last - first) else {
            throw ConfigurationError.invalid("The remote port range must fit within 1–65535.")
        }
        return (first...last, start)
    }

    private func mappingPreview(_ ports: (local: ClosedRange<Int>, remoteStart: Int)) -> String {
        let first = ports.local.lowerBound
        let last = ports.local.upperBound
        let destination = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if first == last { return "localhost:\(first) → \(destination):\(ports.remoteStart)" }
        return "localhost:\(first)–\(last) → \(destination):\(ports.remoteStart)–\(ports.remoteStart + last - first)"
    }
}
