#if DEBUG
import SwiftUI

struct FileIconGalleryRow: View {
    let category: FileCategory

    var body: some View {
        GridRow {
            Text(category.title)
                .font(.callout)
                .frame(width: 88, alignment: .leading)
            FileTypeIcon(category: category, state: .downloading(progress: 0.4),
                         extension: category.representativeExtension, size: 64)
            FileTypeIcon(category: category, state: .completed,
                         extension: category.representativeExtension, size: 64)
            FileTypeIcon(category: category, state: .attention(progress: 0.4),
                         extension: category.representativeExtension, size: 64)
            FileTypeIcon(category: category, state: .engineUnavailable(progress: 0.4),
                         extension: category.representativeExtension, size: 64)
        }
    }
}
#endif
