//
//  ManagePagesSheet.swift
//  JetLedger
//

import SwiftData
import SwiftUI

struct ManagePagesSheet: View {
    let receipt: LocalReceipt

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var orderedPages: [LocalReceiptPage] = []
    @State private var deletedPageIds: Set<UUID> = []
    @State private var showLastPageAlert = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedPages) { page in
                    HStack(spacing: 12) {
                        // Thumbnail
                        Group {
                            let thumbPath = page.localImagePath
                                .replacingOccurrences(of: ".jpg", with: "-thumb.jpg")
                            if let image = ImageUtils.loadReceiptImage(relativePath: thumbPath) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else if let image = ImageUtils.loadReceiptImage(relativePath: page.localImagePath) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(.quaternary)
                                    .overlay {
                                        Image(systemName: "doc")
                                            .foregroundStyle(.secondary)
                                    }
                            }
                        }
                        .frame(width: 44, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        if let index = orderedPages.firstIndex(where: { $0.id == page.id }) {
                            Text("Page \(index + 1)")
                        }
                    }
                }
                .onMove { source, destination in
                    orderedPages.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    if orderedPages.count <= 1 {
                        showLastPageAlert = true
                        return
                    }
                    for index in offsets {
                        deletedPageIds.insert(orderedPages[index].id)
                    }
                    orderedPages.remove(atOffsets: offsets)
                }
                .deleteDisabled(orderedPages.count <= 1)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Manage Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .alert("Cannot Delete", isPresented: $showLastPageAlert) {
                Button("OK") {}
            } message: {
                Text("A receipt must have at least one page. To remove this receipt entirely, use Delete from the actions menu.")
            }
            .onAppear {
                orderedPages = receipt.pages.sorted { $0.sortOrder < $1.sortOrder }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        // Delete removed pages
        for page in receipt.pages where deletedPageIds.contains(page.id) {
            ImageUtils.deletePageImage(relativePath: page.localImagePath)
            modelContext.delete(page)
        }

        // Update sort order on remaining pages
        for (index, page) in orderedPages.enumerated() {
            page.sortOrder = index
        }

        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
