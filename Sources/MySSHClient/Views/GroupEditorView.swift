import SwiftUI

struct GroupEditorView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    let group: HostGroup?
    @State private var name: String
    @State private var parentID: HostGroup.ID?
    @State private var errorMessage: String?

    init(group: HostGroup?, defaultParentID: HostGroup.ID? = nil) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _parentID = State(initialValue: group?.parentID ?? defaultParentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group == nil ? "新增群組" : "編輯群組")
                .font(.title2.weight(.semibold))
            TextField("群組名稱", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("上層群組", selection: $parentID) {
                Text("最上層").tag(Optional<UUID>.none)
                ForEach(store.groupChoices(excludingSubtreeOf: group?.id)) { choice in
                    Text(choice.path).tag(Optional(choice.id))
                }
            }
            .pickerStyle(.menu)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        do {
            if let group { try store.updateGroup(group, name: name, parentID: parentID) }
            else { try store.createGroup(named: name, parentID: parentID) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
