import SwiftUI

/// The filter above the table: All, or the files carrying one mark.
struct FileFilterBar: View {
    @Binding var filter: FileListFilter

    var body: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(FileListFilter.options) { option in
                    Text(option.title)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show only the files with a mark")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
