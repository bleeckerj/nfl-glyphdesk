import CoreText
import Foundation

enum ReviewProjectExport {
    static func pdf(_ project: FontReviewProject, library: FontLibrary) -> Data? {
        guard !project.samples.isEmpty, !project.candidates.isEmpty else { return nil }
        let result = NSMutableData()
        let width = max(612, (project.samples.map(\.measure).max() ?? 540) + 72)
        var media = CGRect(x: 0, y: 0, width: width, height: 792)
        guard let consumer = CGDataConsumer(data: result as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        var page = 0
        for sample in project.samples {
            for candidate in project.candidates {
                let font = ReviewCandidateFont(candidate, size: sample.size, library: library)
                let layout = font?.layout(sample)
                let coverage = layout.flatMap { specimen in font.map { ReviewCoverage(layout: specimen, font: $0.styled) } }
                let pages = layout?.pages(contentHeight: 615) ?? [0..<0]
                for lines in pages {
                    page += 1
                    context.beginPDFPage(nil)
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    ProofOutput.label("\(project.name) · \(sample.name)", x: 36, y: 752, context: context,
                                      size: 14, maxWidth: width - 72)
                    let face = [candidate.reference.displayName, candidate.reference.version].compactMap { $0 }
                    ProofOutput.label(face.joined(separator: " · ") + " · \(sample.size.formatted()) pt",
                                      x: 36, y: 734, context: context, maxWidth: width - 72)
                    ProofOutput.label("Glyph Desk · Project Proof · \(page)", x: 36, y: 30, context: context)
                    if let layout, let coverage {
                        ProofOutput.label("\(coverage.native) native · \(coverage.fallback) fallback · \(coverage.missing) missing",
                                          x: 36, y: 714, context: context)
                        let fonts = fallbackFaces(in: coverage)
                        if !fonts.isEmpty {
                            ProofOutput.label("Fallback fonts: " + fonts, x: 36, y: 698, context: context, maxWidth: width - 72)
                        }
                        if let first = lines.first {
                            let offset = CGPoint(x: 36, y: 675 - layout.lines[first].top)
                            layout.draw(in: context, highlights: coverage.highlights, lines: lines, offset: offset)
                        }
                    } else {
                        ProofOutput.label("Font unavailable", x: 36, y: 714, context: context)
                    }
                    context.endPDFPage()
                }
            }
        }
        context.closePDF()
        return result as Data
    }

    static func csv(_ project: FontReviewProject, library: FontLibrary) -> Data {
        var rows = [["Project", "Order", "Face", "PostScript", "Available", "Source", "File", "Version",
                     "Foundry", "License URL", "Installed matches", "Sample", "Point size", "Measure (pt)",
                     "Line spacing (pt)", "Native", "Fallback", "Missing", "Fallback faces", "Coverage details"]]
        for (index, candidate) in project.candidates.enumerated() {
            for sample in project.samples {
                let proof = ReviewCandidateProof(candidate: candidate, sample: sample, library: library)
                rows.append(fontFields(project: project.name, order: index + 1, proof: proof) + sampleFields(proof))
            }
        }
        let quoted = rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n")
        return Data((quoted + "\r\n").utf8)
    }

    private static func fontFields(project: String, order: Int, proof: ReviewCandidateProof) -> [String] {
        let reference = proof.candidate.reference
        let metadata = proof.font?.metadata
        let matches = metadata?.installedMatches.map { match in
            [match.version, match.filePath].compactMap { $0 }.joined(separator: " · ")
        }.joined(separator: "\n")
        return [project, String(order), reference.displayName, reference.postScriptName,
                metadata == nil ? "No" : "Yes", reference.file == nil ? "Installed" : "Font file",
                metadata?.reference.filePath ?? reference.filePath ?? "",
                reference.version ?? "", metadata?.foundry ?? "", metadata?.licenseURL ?? "", matches ?? ""]
    }

    private static func sampleFields(_ proof: ReviewCandidateProof) -> [String] {
        let sample = proof.sample
        var fields = [sample.name, String(sample.size), String(sample.measure), String(sample.lineSpacing)]
        if let coverage = proof.coverage {
            let issues = coverage.issues.map { issue in
                let fonts = issue.fallbackFaces.map(\.label)
                return (["UTF-16 \(issue.range.lowerBound)", issue.state.rawValue, issue.text] + fonts).joined(separator: " · ")
            }.joined(separator: "\n")
            fields += [String(coverage.native), String(coverage.fallback), String(coverage.missing),
                       fallbackFaces(in: coverage), issues]
        } else {
            fields += ["", "", "", "", "Font unavailable"]
        }
        return fields
    }

    private static func fallbackFaces(in coverage: ReviewCoverage) -> String {
        Set(coverage.issues.flatMap(\.fallbackFaces).map(\.label)).sorted().joined(separator: ", ")
    }

    private static func csvCell(_ field: String) -> String {
        let start = field.drop(while: { $0.isWhitespace }).first
        let escaped = (start.map { "=+-@".contains($0) } == true ? "'" : "") + field
        return "\"" + escaped.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
