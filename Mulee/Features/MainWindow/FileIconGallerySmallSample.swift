#if DEBUG
import SwiftUI

struct FileIconGallerySmallSample: View {
    let category: FileCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                FileTypeIcon(category: category, state: .downloading(progress: 0.4),
                             extension: category.representativeExtension, size: 32)
                FileTypeIcon(category: category, state: .completed,
                             extension: category.representativeExtension, size: 32)
                FileTypeIcon(category: category, state: .downloading(progress: 0.4),
                             extension: category.representativeExtension, size: 16)
                FileTypeIcon(category: category, state: .completed,
                             extension: category.representativeExtension, size: 16)
            }
        }
    }
}
#endif
