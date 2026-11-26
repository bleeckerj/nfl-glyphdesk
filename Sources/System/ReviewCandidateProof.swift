import CoreText
import Foundation

// Core Text font objects are immutable. Layout objects are created on the queue that uses them.
struct ReviewCandidateFont: @unchecked Sendable {
    let base: CTFont
    let styled: CTFont
    let metadata: FontReviewFonts.Metadata

    init?(_ candidate: FontReviewCandidate, size: CGFloat, library: FontLibrary) {
        guard let font = FontReviewFonts.resolve(candidate.reference, size: size, library: library) else { return nil }
        base = font
        styled = ReviewTypography.apply(candidate.typography, to: font)
        metadata = FontReviewFonts.metadata(for: font, reviewingFile: candidate.reference.file != nil, library: library)
    }

    func layout(_ sample: FontReviewSample) -> ReviewSpecimen {
        ReviewSpecimen(sample: sample, font: styled)
    }
}

struct ReviewCandidateProof: Sendable {
    let id = UUID()
    let candidate: FontReviewCandidate
    let sample: FontReviewSample
    let font: ReviewCandidateFont?
    let height: CGFloat
    let coverage: ReviewCoverage?

    init(candidate: FontReviewCandidate, sample: FontReviewSample, library: FontLibrary) {
        self.candidate = candidate
        self.sample = sample
        if let resolved = ReviewCandidateFont(candidate, size: sample.size, library: library) {
            let layout = resolved.layout(sample)
            font = resolved
            height = layout.height
            coverage = ReviewCoverage(layout: layout, font: resolved.styled)
        } else {
            font = nil
            height = 0
            coverage = nil
        }
    }
}
