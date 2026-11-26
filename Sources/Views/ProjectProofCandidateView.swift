import AppKit
import SwiftUI

struct ProjectProofCandidateView: View {
    @ObservedObject var desk: DeskModel
    @ObservedObject var reviews: FontReviewModel
    let candidate: FontReviewCandidate
    let index: Int
    let project: FontReviewProject
    let sample: FontReviewSample
    let proof: ReviewCandidateProof?
    let chooseFile: (FontReviewCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let proof {
                if let font = proof.font, let coverage = proof.coverage {
                    ReviewTypographyControls(font: font.base, settings: Binding(get: {
                        reviews.project?.candidates.first { $0.id == candidate.id }?.typography ?? candidate.typography
                    }, set: { typography in
                        reviews.updateCandidate(candidate.id, in: project.id) { $0.typography = typography }
                    }))
                    sourceDetails(font.metadata)
                    coverageDetails(coverage)
                    ReviewSpecimenView(proof: proof)
                        .frame(width: proof.sample.measure, height: proof.height, alignment: .topLeading)
                        .accessibilityLabel(Text(proof.sample.text))
                } else {
                    Text("Font unavailable").foregroundStyle(.secondary)
                    if let path = candidate.reference.filePath {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    relinkButton
                }
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Checking font coverage")
            }
        }
        .frame(width: max(1, sample.measure), alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func coverageDetails(_ coverage: ReviewCoverage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(coverage.native) native")
                Text("\(coverage.fallback) fallback")
                    .padding(.horizontal, 4).background(Color(cgColor: ReviewCoverage.State.fallback.highlightColor))
                Text("\(coverage.missing) missing")
                    .padding(.horizontal, 4).background(Color(cgColor: ReviewCoverage.State.missing.highlightColor))
            }
            if !coverage.issues.isEmpty {
                DisclosureGroup("Coverage details") {
                    let groups = Dictionary(grouping: coverage.issues) { issue in
                        CoverageItem(text: issue.text, state: issue.state, faces: issue.fallbackFaces)
                    }
                    let keys = groups.keys.sorted { ($0.state.rawValue, $0.text) < ($1.state.rawValue, $1.text) }
                    ForEach(keys, id: \.self) { item in
                        let count = groups[item]?.count ?? 0
                        Text("\(item.text) · \(item.state.rawValue)\(count > 1 ? " ×\(count)" : "")")
                            .fontWeight(.medium)
                        if !item.faces.isEmpty {
                            Text(item.faces.map(\.label).joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                    }
                }.textSelection(.enabled)
            }
        }.font(.caption)
    }

    private struct CoverageItem: Hashable {
        let text: String
        let state: ReviewCoverage.State
        let faces: [ReviewCoverage.FallbackFace]
    }

    private var header: some View {
        HStack {
            Text(candidate.reference.displayName).font(.headline).lineLimit(1)
                .help(candidate.reference.displayName)
            Spacer()
            Button { reviews.moveCandidate(candidate.id, in: project.id, by: -1) } label: {
                Label("Move font left", systemImage: "chevron.left")
            }.disabled(index == 0)
            Button { reviews.moveCandidate(candidate.id, in: project.id, by: 1) } label: {
                Label("Move font right", systemImage: "chevron.right")
            }.disabled(index == project.candidates.count - 1)
            Button {
                reviews.updateProject(project.id) { $0.candidates.removeAll { $0.id == candidate.id } }
            } label: {
                Label("Remove font from project", systemImage: "minus.circle")
            }
        }.buttonStyle(.borderless).labelStyle(.iconOnly)
    }

    private func sourceDetails(_ metadata: FontReviewFonts.Metadata) -> some View {
        DisclosureGroup(candidate.reference.file == nil ? "Installed font" : "Font file") {
            VStack(alignment: .leading, spacing: 5) {
                Text(metadata.reference.postScriptName).fontWeight(.medium)
                if let version = metadata.reference.version { LabeledContent("Version", value: version) }
                if let foundry = metadata.foundry { LabeledContent("Foundry", value: foundry) }
                if let license = metadata.licenseURL { LabeledContent("License URL", value: license) }
                if let path = metadata.reference.filePath { Text(path).textSelection(.enabled) }
                if candidate.reference.file != nil {
                    Text("Installed faces with the same PostScript name").fontWeight(.medium).padding(.top, 5)
                    if metadata.installedMatches.isEmpty {
                        Text("No matching installed faces").foregroundStyle(.secondary)
                    }
                    ForEach(metadata.installedMatches, id: \.self) { match in
                        Text([match.version, match.filePath].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    relinkButton
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .font(.callout)
    }

    @ViewBuilder private var relinkButton: some View {
        if candidate.reference.file != nil {
            Button("Relink Font File…") { chooseFile(candidate) }
        } else {
            Button("Relink to Selected Font") {
                guard let face = desk.selectedFace else { return }
                let reference = FontReviewFonts.reference(for: face)
                reviews.updateCandidate(candidate.id, in: project.id) { $0.reference = reference }
            }.disabled(desk.selectedFace == nil)
        }
    }
}

private struct ReviewSpecimenView: NSViewRepresentable {
    let proof: ReviewCandidateProof

    func makeNSView(context: Context) -> Canvas { Canvas() }

    func updateNSView(_ view: Canvas, context: Context) {
        guard view.proofID != proof.id else { return }
        view.proofID = proof.id
        view.specimen = proof.font?.layout(proof.sample)
        view.highlights = proof.coverage?.highlights ?? [:]
        view.needsDisplay = true
    }

    final class Canvas: NSView {
        var proofID: UUID?
        var specimen: ReviewSpecimen?
        var highlights: [Int: [ReviewCoverage.Highlight]] = [:]

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setFillColor(NSColor.labelColor.cgColor)
            specimen?.draw(in: context, highlights: highlights)
        }
    }
}
