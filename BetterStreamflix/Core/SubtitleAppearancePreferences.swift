import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Caption appearance applied through `AVTextStyleRule` on the current player item.
enum SubtitleAppearancePreferences {
    static let sizeKey = "player.subtitleAppearance.size"
    static let styleKey = "player.subtitleAppearance.style"
    static let colorKey = "player.subtitleAppearance.color"
    static let didChangeNotification = Notification.Name("player.subtitleAppearance.didChange")

    enum Size: String, CaseIterable, Identifiable {
        case small
        case standard
        case large
        case extraLarge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: "Small"
            case .standard: "Standard"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }

        /// Percentage of the default caption size (`kCMTextMarkupAttribute_RelativeFontSize`).
        var relativeFontSize: Int {
            switch self {
            case .small: 80
            case .standard: 100
            case .large: 130
            case .extraLarge: 160
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case dropShadow
        case outline
        case background
        case clean

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dropShadow: "Drop shadow"
            case .outline: "Outline"
            case .background: "Background"
            case .clean: "Clean"
            }
        }
    }

    enum ColorOption: String, CaseIterable, Identifiable {
        case white
        case yellow
        case cyan
        case softGray

        var id: String { rawValue }

        var title: String {
            switch self {
            case .white: "White"
            case .yellow: "Yellow"
            case .cyan: "Cyan"
            case .softGray: "Soft gray"
            }
        }

        /// ARGB components in 0…1 for Core Media text markup.
        var argb: [CGFloat] {
            switch self {
            case .white: [1, 1, 1, 1]
            case .yellow: [1, 1, 0.92, 0.23]
            case .cyan: [1, 0.45, 0.92, 1]
            case .softGray: [1, 0.88, 0.88, 0.88]
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sizeKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .dropShadow }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: styleKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var color: ColorOption {
        get { ColorOption(rawValue: UserDefaults.standard.string(forKey: colorKey) ?? "") ?? .white }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: colorKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func textStyleRules(
        size: Size = size,
        style: Style = style,
        color: ColorOption = color
    ) -> [AVTextStyleRule] {
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: color.argb,
            kCMTextMarkupAttribute_RelativeFontSize as String: size.relativeFontSize,
            kCMTextMarkupAttribute_BoldStyle as String: true,
        ]

        switch style {
        case .dropShadow:
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_DropShadow
        case .outline:
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_Uniform
        case .background:
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] =
                [CGFloat(0.55), CGFloat(0), CGFloat(0), CGFloat(0)]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_None
        case .clean:
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_None
        }

        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else { return [] }
        return [rule]
    }
}
