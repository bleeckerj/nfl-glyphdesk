import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProofView: View {
    @ObservedObject var model: DeskModel
    @State private var isProjectProof = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Proof mode", selection: $isProjectProof) {
                Text("Single Font").tag(false)
                Text("Project Proof").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.top, 12)
            if isProjectProof {
                ProjectProofView(desk: model, reviews: model.fontReviews)
            } else {
                SingleFontProofView(model: model)
            }
        }
    }
}

struct ProjectProofView: View {
    @ObservedObject var desk: DeskModel
    @ObservedObject var reviews: FontReviewModel
    @State private var fileChoice: ReviewFileChoice?
    @State private var isExporting = false
    @State private var nativeOnly = false
    @State private var results: AnalysisResults?

    private struct AnalysisRequest: Equatable, Sendable {
        let sample: FontReviewSample
        let candidates: [FontReviewCandidate]
        let libraryID: ObjectIdentifier
    }

    private struct AnalysisResults {
        let request: AnalysisRequest
        let proofs: [UUID: ReviewCandidateProof]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let project = reviews.project {
                    Picker("Project", selection: Binding(get: { reviews.project?.id ?? project.id }, set: reviews.selectProject)) {
                        ForEach(reviews.library.projects) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }
                Button("New Project", action: reviews.createProject)
                Spacer()
                if let project = reviews.project {
                    Button("Add Selected Font") { addSelectedFont(to: project.id) }
                        .disabled(desk.selectedFace == nil)
                    Button("Open Font File…") { chooseFile(in: project.id) }
                    Menu("Export") {
                        Button("Project Proof PDF…") { export(project, asPDF: true) }
                        Button("Shortlist and Coverage CSV…") { export(project, asPDF: false) }
                    }.disabled(project.candidates.isEmpty || isExporting)
                }
            }
            if let error = reviews.storageError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if let project = reviews.project, let sample = project.activeSample {
                editor(project, sample: sample)
                if project.candidates.isEmpty {
                    EmptyPane(title: "Add a font to the project",
                              detail: "Add a face from the sidebar or open a font file.")
                } else {
                    proofs(for: project, sample: sample)
                }
            } else {
                EmptyPane(title: "Project Proof", detail: "Save a font shortlist and compare it with your own text.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $fileChoice) { choice in
            ReviewFileFacePicker(choice: choice, select: { reference in
                useFile(reference, for: choice)
                fileChoice = nil
            }, cancel: { fileChoice = nil })
        }
    }

    private func proofs(for project: FontReviewProject, sample: FontReviewSample) -> some View {
        let request = AnalysisRequest(sample: sample, candidates: project.candidates, libraryID: ObjectIdentifier(desk.library))
        let ready = results?.request == request
        let candidates = project.candidates.enumerated().filter { _, candidate in
            !nativeOnly || (ready && results?.proofs[candidate.id]?.coverage?.isAllNative == true)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Complete native coverage", isOn: $nativeOnly)
                    .help("Show fonts that render every visible text cluster in the active sample natively.")
                if !ready { ProgressView().controlSize(.small).accessibilityLabel("Updating coverage") }
            }
            if candidates.isEmpty && ready {
                EmptyPane(title: "No fonts cover this sample",
                          detail: "Turn off Complete native coverage to see the fallback and missing text.")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(candidates, id: \.element.id) { index, candidate in
                            let cached = results?.proofs[candidate.id]
                            let proof = cached?.candidate.reference == candidate.reference && cached?.sample.id == sample.id
                                ? cached : nil
                            ProjectProofCandidateView(desk: desk, reviews: reviews, candidate: candidate, index: index,
                                                      project: project, sample: sample, proof: proof) {
                                chooseFile(in: project.id, relinking: $0)
                            }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .task(id: request) { await analyze(request, library: desk.library) }
    }

    private func analyze(_ request: AnalysisRequest, library: FontLibrary) async {
        if results?.request == request { return }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        let worker = Task.detached(priority: .userInitiated) {
            var proofs: [UUID: ReviewCandidateProof] = [:]
            for candidate in request.candidates {
                guard !Task.isCancelled else { break }
                proofs[candidate.id] = ReviewCandidateProof(candidate: candidate, sample: request.sample, library: library)
            }
            return proofs
        }
        let proofs = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        results = AnalysisResults(request: request, proofs: proofs)
    }

    private func editor(_ project: FontReviewProject, sample: FontReviewSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Project name", text: Binding(get: {
                    reviews.library.projects.first { $0.id == project.id }?.name ?? project.name
                }, set: { value in
                    reviews.updateProject(project.id) { $0.name = value }
                }))
                .accessibilityLabel("Project name")
                Picker("Sample", selection: Binding(get: { reviews.project?.activeSample?.id ?? sample.id }, set: { id in
                    reviews.updateProject(project.id) { $0.activeSampleID = id }
                })) {
                    ForEach(project.samples) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Button("New Sample") { reviews.addSample(to: project.id) }
            }
            TextField("Sample name", text: sampleBinding(\.name, sample, project: project.id))
                .accessibilityLabel("Sample name")
            TextEditor(text: sampleBinding(\.text, sample, project: project.id))
                .font(.body)
                .frame(height: 92)
                .accessibilityLabel("Project proof text")
                .overlay(Rectangle().strokeBorder(.secondary.opacity(0.3)))
            HStack(spacing: 12) {
                Stepper(value: sampleBinding(\.size, sample, project: project.id), in: 9...144) {
                    Text("Size \(sample.size.formatted()) pt")
                }
                Stepper(value: sampleBinding(\.measure, sample, project: project.id), in: 160...720, step: 20) {
                    Text("Width \(sample.measure.formatted()) pt")
                }
                Stepper(value: sampleBinding(\.lineSpacing, sample, project: project.id), in: 0...48) {
                    Text("Line spacing \(sample.lineSpacing.formatted()) pt")
                }
            }.font(.callout)
        }
    }

    private func sampleBinding<Value>(_ property: WritableKeyPath<FontReviewSample, Value>,
                                      _ sample: FontReviewSample, project: UUID) -> Binding<Value> {
        Binding(get: {
            let current = reviews.library.projects.first { $0.id == project }?.samples.first { $0.id == sample.id }
            return (current ?? sample)[keyPath: property]
        }, set: { value in
            reviews.updateSample(sample.id, in: project) { $0[keyPath: property] = value }
        })
    }

    private func addSelectedFont(to projectID: UUID) {
        guard let face = desk.selectedFace else { return }
        let candidate = FontReviewCandidate(reference: FontReviewFonts.reference(for: face))
        reviews.updateProject(projectID) { $0.candidates.append(candidate) }
    }

    private func chooseFile(in projectID: UUID, relinking candidate: FontReviewCandidate? = nil) {
        guard let choice = ReviewFileChoice.choose(projectID: projectID, candidate: candidate, desk: desk) else { return }
        if choice.faces.count == 1, let reference = choice.faces.first?.reference {
            useFile(reference, for: choice)
        } else {
            fileChoice = choice
        }
    }

    private func useFile(_ reference: FontReviewReference, for choice: ReviewFileChoice) {
        if let candidateID = choice.candidateID {
            reviews.updateCandidate(candidateID, in: choice.projectID) { $0.reference = reference }
        } else {
            let candidate = FontReviewCandidate(reference: reference)
            reviews.updateProject(choice.projectID) { $0.candidates.append(candidate) }
        }
    }

    private func export(_ project: FontReviewProject, asPDF: Bool) {
        isExporting = true
        let library = desk.library
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                asPDF ? ReviewProjectExport.pdf(project, library: library) : ReviewProjectExport.csv(project, library: library)
            }.value
            isExporting = false
            guard let data else {
                desk.message = String(localized: "The project proof could not be exported.")
                return
            }
            let type: UTType = asPDF ? .pdf : .commaSeparatedText
            WorkspaceFiles.save(data, type: type, name: project.name + (asPDF ? ".pdf" : ".csv"), model: desk)
        }
    }
}
