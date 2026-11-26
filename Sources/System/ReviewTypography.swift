import CoreText
import Foundation

enum ReviewTypography {
    struct Axis: Identifiable {
        let id: UInt32
        let name: String
        let minimum: Double
        let maximum: Double
        let defaultValue: Double
    }

    struct Feature: Identifiable {
        let id: String
        let name: String
    }

    static func axes(in font: CTFont) -> [Axis] {
        let definitions = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        let instance = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
        return definitions.compactMap { definition in
            guard let identifier = definition[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                  let minimum = definition[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber,
                  let maximum = definition[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber,
                  let value = definition[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber,
                  minimum.doubleValue < maximum.doubleValue,
                  (definition[kCTFontVariationAxisHiddenKey as String] as? Bool) != true else { return nil }
            let name = definition[kCTFontVariationAxisNameKey as String] as? String ?? identifier.stringValue
            return Axis(id: identifier.uint32Value, name: name, minimum: minimum.doubleValue,
                        maximum: maximum.doubleValue, defaultValue: instance[identifier]?.doubleValue ?? value.doubleValue)
        }
    }

    static func features(in font: CTFont) -> [Feature] {
        var advertised = FontTableReader(font).featureTags()
        let available = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
        let ligatures = available.first {
            ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == kLigaturesType
        }
        let selectors = ligatures?[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? []
        let selectorIDs = Set(selectors.compactMap { $0[kCTFontFeatureSelectorIdentifierKey as String] as? Int })
        if selectorIDs.contains(kCommonLigaturesOnSelector) { advertised.insert("liga") }
        if selectorIDs.contains(kRareLigaturesOnSelector) { advertised.insert("dlig") }
        let standard = [
            Feature(id: "kern", name: String(localized: "Kerning")),
            Feature(id: "liga", name: String(localized: "Standard ligatures")),
            Feature(id: "dlig", name: String(localized: "Discretionary ligatures")),
            Feature(id: "smcp", name: String(localized: "Small caps")),
            Feature(id: "c2sc", name: String(localized: "Capitals to small caps")),
            Feature(id: "tnum", name: String(localized: "Tabular figures")),
            Feature(id: "onum", name: String(localized: "Old-style figures")),
            Feature(id: "frac", name: String(localized: "Fractions"))
        ]
        let stylistic = (1...20).map { index in
            Feature(id: String(format: "ss%02d", index), name: String(localized: "Stylistic set \(index)"))
        }
        return (standard + stylistic).filter { advertised.contains($0.id) }
    }

    static func apply(_ settings: ReviewTypeSettings, to font: CTFont) -> CTFont {
        guard !settings.isDefault else { return font }
        var descriptor = CTFontCopyFontDescriptor(font)
        if !settings.axes.isEmpty {
            for axis in axes(in: font) {
                guard let value = settings.axes[axis.id], value.isFinite else { continue }
                descriptor = CTFontDescriptorCreateCopyWithVariation(
                    descriptor, NSNumber(value: axis.id), min(max(value, axis.minimum), axis.maximum)
                )
            }
        }
        if !settings.features.isEmpty {
            let settingsList = features(in: font).compactMap { feature -> [String: Any]? in
                guard let enabled = settings.features[feature.id] else { return nil }
                return [
                    kCTFontOpenTypeFeatureTag as String: feature.id,
                    kCTFontOpenTypeFeatureValue as String: enabled ? 1 : 0
                ]
            }
            if !settingsList.isEmpty {
                let attributes = [kCTFontFeatureSettingsAttribute as String: settingsList] as CFDictionary
                descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
            }
        }
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }
}
