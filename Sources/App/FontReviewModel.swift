import Combine
import Foundation

@MainActor
final class FontReviewModel: ObservableObject {
    @Published private(set) var library: FontReviewLibrary
    @Published private(set) var storageError: String?

    private let store: FontReviewStore
    private let canSave: Bool
    private var needsSave = false
    private var saveTask: Task<Void, Never>?

    init(store: FontReviewStore = FontReviewStore()) {
        self.store = store
        do {
            library = try store.load()
            canSave = true
        } catch {
            library = FontReviewLibrary()
            canSave = false
            storageError = String(localized: "Saved projects could not be opened. The existing file was preserved.")
        }
    }

    var project: FontReviewProject? {
        library.projects.first { $0.id == library.activeProjectID } ?? library.projects.first
    }

    func createProject() {
        let name = String(localized: "Untitled project")
        let newProject = FontReviewProject(name: name)
        library.projects.append(newProject)
        selectProject(newProject.id)
    }

    func selectProject(_ id: UUID) {
        guard library.projects.contains(where: { $0.id == id }) else { return }
        library.activeProjectID = id
        scheduleSave()
    }

    func updateProject(_ id: UUID, _ update: (inout FontReviewProject) -> Void) {
        guard let index = library.projects.firstIndex(where: { $0.id == id }) else { return }
        update(&library.projects[index])
        scheduleSave()
    }

    func addSample(to id: UUID) {
        updateProject(id) { project in
            let sample = FontReviewSample(name: String(localized: "Sample \(project.samples.count + 1)"))
            project.samples.append(sample)
            project.activeSampleID = sample.id
        }
    }

    func updateSample(_ id: UUID, in projectID: UUID, _ update: (inout FontReviewSample) -> Void) {
        updateProject(projectID) { project in
            guard let index = project.samples.firstIndex(where: { $0.id == id }) else { return }
            update(&project.samples[index])
        }
    }

    func updateCandidate(_ id: UUID, in projectID: UUID, _ update: (inout FontReviewCandidate) -> Void) {
        updateProject(projectID) { project in
            guard let index = project.candidates.firstIndex(where: { $0.id == id }) else { return }
            update(&project.candidates[index])
        }
    }

    func moveCandidate(_ id: UUID, in projectID: UUID, by offset: Int) {
        updateProject(projectID) { project in
            guard let index = project.candidates.firstIndex(where: { $0.id == id }),
                  project.candidates.indices.contains(index + offset) else { return }
            project.candidates.swapAt(index, index + offset)
        }
    }

    func saveImmediately() {
        saveTask?.cancel()
        saveTask = nil
        guard canSave, needsSave else { return }
        do {
            try store.save(library)
            needsSave = false
            storageError = nil
        } catch {
            storageError = String(localized: "Projects could not be saved. \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        guard canSave else { return }
        needsSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveImmediately()
        }
    }
}
