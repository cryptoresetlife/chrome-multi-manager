import SwiftUI

struct ProfileEditorView: View {
    @Binding var profile: ChromeProfile
    let title: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                        .foregroundStyle(.secondary)
                    TextField("账号", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("分组")
                        .foregroundStyle(.secondary)
                    TextField("默认", text: $profile.group)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("代理")
                        .foregroundStyle(.secondary)
                    TextField("http://用户名:密码@IP:端口 或 IP:端口", text: $profile.proxy)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("备注")
                        .foregroundStyle(.secondary)
                    TextField("", text: $profile.note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("代理格式: http://用户名:密码@IP:端口 或 IP:端口")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("确定") {
                    normalize()
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func normalize() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.group = profile.group.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.proxy = profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.note = profile.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.name.isEmpty {
            profile.name = "账号\(profile.id)"
        }
        if profile.group.isEmpty {
            profile.group = "默认"
        }
        if profile.debugPort == 0 {
            profile.debugPort = ChromeProfile.nextDebugPort(for: profile.id)
        }
    }
}
