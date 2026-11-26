import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReviewFileChoice: Identifiable {
    let id = UUID()
    let faces: [FontReviewFonts.FileFace]
    let projectID: UUID
    let candidateID: UUID?

    @MainActor
    static func choose(projectID: UUID, candidate: FontReviewCandidate?, desk: DeskModel) -> Self? {
        let panel = NSOpenPanel()
        panel.title = candidate == nil ? String(localized: "Open Font File") : String(localized: "Relink Font File")
        panel.allowedContentTypes = ["otf", "ttf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let faces = try FontReviewFonts.open(url)
            let eligible = candidate.map { current in
                faces.filter { $0.reference.postScriptName == current.reference.postScriptName }
            } ?? faces
            guard !eligible.isEmpty else {
                desk.message = String(localized: "This file does not contain \(candidate?.reference.postScriptName ?? "").")
                return nil
            }
            return Self(faces: eligible, projectID: projectID, candidateID: candidate?.id)
        } catch {
            desk.message = error.localizedDescription
            return nil
        }
    }
}

struct ReviewFileFacePicker: View {
    let choice: ReviewFileChoice
    let select: (FontReviewReference) -> Void
    let cancel: () -> Void
    @State private var selectedFace: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a face").font(.headline)
            if let path = choice.faces.first?.reference.filePath {
                Text(URL(fileURLWithPath: path).lastPathComponent).foregroundStyle(.secondary)
            }
            List(choice.faces, selection: $selectedFace) { face in
                VStack(alignment: .leading, spacing: 3) {
                    Text(face.reference.displayName)
                    Text(face.reference.postScriptName).font(.caption).foregroundStyle(.secondary)
                }
                .tag(face.id)
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Use Face") {
                    if let face = choice.faces.first(where: { $0.id == selectedFace }) { select(face.reference) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedFace == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { selectedFace = choice.faces.first?.id }
    }
}
