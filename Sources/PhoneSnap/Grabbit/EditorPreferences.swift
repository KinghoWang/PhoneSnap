import AppKit

// MARK: - Preference keys

enum Prefs {
    static let borderWeight      = "phonesnap.editor.borderWeight"
    static let borderColor       = "phonesnap.editor.borderColor"
    static let shadowX           = "phonesnap.editor.shadowX"
    static let shadowY           = "phonesnap.editor.shadowY"
    static let shadowBlur        = "phonesnap.editor.shadowBlur"
    static let shadowColor       = "phonesnap.editor.shadowColor"
    static let shadowOpacity     = "phonesnap.editor.shadowOpacity"
    static let arrowWeight       = "phonesnap.editor.arrowWeight"
    static let arrowColor        = "phonesnap.editor.arrowColor"
    static let borderEnabled     = "phonesnap.editor.borderEnabled"
    static let shadowEnabled     = "phonesnap.editor.shadowEnabled"
    static let textFontName      = "phonesnap.editor.textFontName"
    static let textFontSize      = "phonesnap.editor.textFontSize"
    static let textFontColor     = "phonesnap.editor.textFontColor"
    static let textOutlineColor  = "phonesnap.editor.textOutlineColor"
    static let textOutlineWeight = "phonesnap.editor.textOutlineWeight"
    static let shapeBorderWeight = "phonesnap.editor.shapeBorderWeight"
    static let shapeBorderColor  = "phonesnap.editor.shapeBorderColor"
    static let shapeFillColor    = "phonesnap.editor.shapeFillColor"
    static let stepDiameter      = "phonesnap.editor.stepDiameter"
    static let stepFillColor     = "phonesnap.editor.stepFillColor"
    static let stepTextColor     = "phonesnap.editor.stepTextColor"
    static let libraryPath       = "phonesnap.editor.libraryPath"
    static let footerHeight      = "phonesnap.editor.footerHeight"
}

// MARK: - UserDefaults helpers

func loadDouble(_ key: String, default def: Double) -> Double {
    UserDefaults.standard.object(forKey: key) != nil
        ? UserDefaults.standard.double(forKey: key) : def
}

func loadColor(_ key: String, default def: NSColor) -> NSColor {
    guard let data = UserDefaults.standard.data(forKey: key),
          let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    else { return def }
    return c
}

func loadString(_ key: String, default def: String) -> String {
    UserDefaults.standard.string(forKey: key) ?? def
}

func saveDouble(_ value: Double, key: String) {
    UserDefaults.standard.set(value, forKey: key)
}

func saveColor(_ color: NSColor, key: String) {
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
        UserDefaults.standard.set(data, forKey: key)
    }
}

func saveString(_ value: String, key: String) {
    UserDefaults.standard.set(value, forKey: key)
}

// MARK: - Tool mode

enum ToolMode { case none, arrow, text, shape, crop, blur, highlight, ocr, spotlight, step }
