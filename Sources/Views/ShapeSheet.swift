import SwiftUI

struct ShapeSheet: View {
    @ObservedObject var model: DeskModel
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [Stroke] = []
    @State private var redo: [Stroke] = []
    @State private var active: [CGPoint] = []
    @State private var guides = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find by shape").font(.title2.weight(.semibold))
                    Text("Draw one or more strokes. Include any dots or marks.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Guides", isOn: $guides).toggleStyle(.switch)
            }
            Canvas { context, size in
                if guides {
                    var grid = Path()
                    let inset: CGFloat = 20
                    for number in 1...3 {
                        let x = inset + (size.width - inset * 2) * CGFloat(number) / 4
                        let y = inset + (size.height - inset * 2) * CGFloat(number) / 4
                        grid.move(to: CGPoint(x: x, y: inset))
                        grid.addLine(to: CGPoint(x: x, y: size.height - inset))
                        grid.move(to: CGPoint(x: inset, y: y))
                        grid.addLine(to: CGPoint(x: size.width - inset, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                for line in strokes.map(\.points) + [active] {
                    guard let first = line.first else { continue }
                    if line.count == 1 {
                        context.fill(Path(ellipseIn: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)),
                                     with: .color(.primary))
                    } else {
                        var path = Path()
                        path.move(to: first)
                        path.addLines(Array(line.dropFirst()))
                        context.stroke(path, with: .color(.primary),
                                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.35)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { step in
                if active.isEmpty { active.append(step.startLocation) }
                if active.last != step.location { active.append(step.location) }
            }.onEnded { _ in
                if !active.isEmpty {
                    strokes.append(Stroke(points: active))
                    active = []
                    redo = []
                }
            })
            .frame(width: 400, height: 300)
            .accessibilityLabel("Drawing canvas")
            .accessibilityHint("Draw with a mouse or trackpad, or use text search to find a character.")
            HStack {
                Button("Undo") { if let stroke = strokes.popLast() { redo.append(stroke) } }
                    .disabled(strokes.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button("Redo") { if let stroke = redo.popLast() { strokes.append(stroke) } }
                    .disabled(redo.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Clear") { strokes.removeAll(); redo.removeAll() }.disabled(strokes.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Find") {
                    model.searchSketch(strokes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
