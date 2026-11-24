import Carbon
import Foundation

enum KeyboardMap {
    static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    static func equivalent(for entry: CharacterEntry) -> String? {
        guard !entry.text.isEmpty, entry.category != "Cc", entry.category != "Cf",
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let modifiers: [(UInt32, String)] = [(0, ""), (UInt32(shiftKey >> 8), "⇧"),
                                              (UInt32(optionKey >> 8), "⌥"), (UInt32((optionKey | shiftKey) >> 8), "⌥⇧")]
        var keys: [(UInt16, UInt32, String)] = []
        for (mask, label) in modifiers {
            for key in UInt16(0)..<128 {
                let base = translate(layout, key: key, modifiers: 0, state: 0, noDead: true).text
                if !base.isEmpty, base.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    keys.append((key, mask, label + (base == " " ? "Space" : base.uppercased())))
                }
            }
        }
        var dead: [(UInt32, String)] = []
        for (key, mask, label) in keys {
            let result = translate(layout, key: key, modifiers: mask, state: 0, noDead: false)
            if result.state == 0, result.text == entry.text { return label }
            if result.state != 0 { dead.append((result.state, label)) }
        }
        for (state, first) in dead {
            for (key, mask, second) in keys {
                let result = translate(layout, key: key, modifiers: mask, state: state, noDead: false)
                if result.state == 0, result.text == entry.text { return "\(first), \(second)" }
            }
        }
        return nil
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, key: UInt16,
                                  modifiers: UInt32, state: UInt32, noDead: Bool) -> (text: String, state: UInt32) {
        var state = state
        var length = 0
        var output = [UniChar](repeating: 0, count: 12)
        let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                    noDead ? OptionBits(kUCKeyTranslateNoDeadKeysMask) : 0,
                                    &state, output.count, &length, &output)
        return (status == noErr ? String(utf16CodeUnits: output, count: length) : "", state)
    }
}
