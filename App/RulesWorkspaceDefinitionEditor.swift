import RiftControl
import RiftCore
import SwiftUI

struct RuleDefinitionEditorSheet: View {
    let editor: RuleDefinitionEditor
    let save: @MainActor (String, String, OperationMode?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    @State private var mode: OperationMode?
    @State private var isSaving = false
    @State private var failureMessage: String?

    init(
        editor: RuleDefinitionEditor,
        save: @escaping @MainActor (String, String, OperationMode?) async -> Bool
    ) {
        self.editor = editor
        self.save = save
        switch editor {
        case .newProfile:
            _name = State(initialValue: "")
            _note = State(initialValue: "")
            _mode = State(initialValue: nil)
        case .profile(let profile):
            _name = State(initialValue: profile.name)
            _note = State(initialValue: "")
            _mode = State(initialValue: profile.operationModeOverride)
        case .newGroup:
            _name = State(initialValue: "")
            _note = State(initialValue: "")
            _mode = State(initialValue: nil)
        case .group(let group):
            _name = State(initialValue: group.name)
            _note = State(initialValue: group.note)
            _mode = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                if isGroup {
                    Section("Note") {
                        TextEditor(text: $note)
                            .frame(minHeight: 72)
                    }
                }
                if isExistingProfile {
                    Section("Mode") {
                        Picker("Mode", selection: $mode) {
                            Text("Use Default Mode").tag(OperationMode?.none)
                            Text("Alert").tag(Optional(OperationMode.alert))
                            Text("Silent Allow").tag(Optional(OperationMode.silentAllow))
                            Text("Silent Deny").tag(Optional(OperationMode.silentDeny))
                            Text("Observe Only").tag(Optional(OperationMode.filterOff))
                        }
                    }
                }
                if let failureMessage {
                    Section { Text(failureMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 420, height: isGroup ? 300 : 230)
    }

    private var title: String {
        switch editor {
        case .newProfile: "New Profile"
        case .profile: "Edit Profile"
        case .newGroup: "New Group"
        case .group: "Edit Group"
        }
    }

    private var isGroup: Bool {
        if case .newGroup = editor { return true }
        if case .group = editor { return true }
        return false
    }

    private var isExistingProfile: Bool {
        if case .profile = editor { return true }
        return false
    }

    private func submit() {
        failureMessage = nil
        do {
            _ = try PolicyDefinitionValidator.name(name)
            if isGroup { _ = try PolicyDefinitionValidator.note(note) }
        } catch {
            failureMessage = "Use a shorter name or note."
            return
        }
        isSaving = true
        Task { @MainActor in
            let didSave = await save(name, note, mode)
            isSaving = false
            if didSave {
                dismiss()
            } else {
                failureMessage = "The change wasn’t saved. Make sure the name isn’t already in use, then try again."
            }
        }
    }
}

struct RuleBlocklistImportSheet: View {
    @Bindable var model: RulesWorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isImporting = false
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Blocklist name", text: $name)
                }
                Section {
                    Button("Choose File and Import…") { chooseFile() }
                        .disabled(isImporting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Choose a hosts file or a list of domains, IP addresses, or IP ranges stored on this Mac.")
                }
                if let failureMessage {
                    Section { Text(failureMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import Blocklist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .frame(width: 440, height: 250)
    }

    private func chooseFile() {
        isImporting = true
        failureMessage = nil
        Task { @MainActor in
            do {
                guard let data = try await ArchiveFileAccess.open(
                    maximumBytes: BlocklistParser.maximumBytes
                ) else {
                    isImporting = false
                    return
                }
                if await model.importBlocklist(data: data, name: name) {
                    dismiss()
                } else {
                    failureMessage = "Rift couldn’t import this file. Your blocklists haven’t changed."
                }
            } catch {
                failureMessage = "Rift couldn’t read this file."
            }
            isImporting = false
        }
    }
}
