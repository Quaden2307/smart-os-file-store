import SwiftUI

/// The filter above the table: All, or the files carrying one mark.
struct FileFilterBar: View {
    @Binding var filter: FileListFilter

    var body: some View {
        HStack {
            // Segments while the window has room for all of them, a pop-up menu when it does not.
            ViewThatFits(in: .horizontal) {
                picker
                    .pickerStyle(.segmented)
                    .fixedSize()
                picker
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .barInset()
    }

    private var picker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(FileListFilter.options) { option in
                Text(option.title)
                    .tag(option)
            }
        }
        .labelsHidden()
        .help("Show only the files with a mark")
    }
}
