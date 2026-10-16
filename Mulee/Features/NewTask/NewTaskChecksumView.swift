import SwiftUI

struct NewTaskChecksumView: View {
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("校验值（可选，MD5 / SHA-1 / SHA-256）", text: $item.checksumText)
                .textFieldStyle(.roundedBorder)
            if item.hasInvalidChecksum {
                Text("校验值格式无效，请粘贴完整的 MD5、SHA-1 或 SHA-256。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
