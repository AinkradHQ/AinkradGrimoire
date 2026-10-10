import AinkradAppKit
import Foundation
import GrimoireFeature

/// The bundle's principal class (matches `NSPrincipalClass` in Info.plist).
@objc(GrimoirePluginEntryPoint)
final class GrimoirePluginEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { GrimoireApp.self }
}
