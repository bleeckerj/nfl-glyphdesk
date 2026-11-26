import SwiftUI
import CoreText

struct ReviewTypographyControls: View {
    let font: CTFont
    @Binding var settings: ReviewTypeSettings
    @State private var expanded = false

    var body: some View {
        let axes = ReviewTypography.axes(in: font)
        let features = ReviewTypography.features(in: font)
        if !axes.isEmpty || !features.isEmpty || !settings.isDefault {
            DisclosureGroup("Typography", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(axes) { axis in
                        let value = settings.axes[axis.id] ?? axis.defaultValue
                        HStack {
                            Text(axis.name)
                            Spacer()
                            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: {
                            min(max(settings.axes[axis.id] ?? axis.defaultValue, axis.minimum), axis.maximum)
                        }, set: { value in
                            settings.axes[axis.id] = value == axis.defaultValue ? nil : value
                        }), in: axis.minimum...axis.maximum)
                        .accessibilityLabel(Text(axis.name))
                    }
                    ForEach(features) { feature in
                        Picker(feature.name, selection: Binding(get: {
                            settings.features[feature.id]
                        }, set: { value in
                            settings.features[feature.id] = value
                        })) {
                            Text("Font Default").tag(Optional<Bool>.none)
                            Text("On").tag(Optional(true))
                            Text("Off").tag(Optional(false))
                        }
                    }
                    Button("Reset Typography") { settings = ReviewTypeSettings() }
                        .disabled(settings.isDefault)
                }
                .font(.callout)
                .padding(.vertical, 5)
            }
        }
    }
}
