import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "astra" asset catalog image resource.
    static let astra = DeveloperToolsSupport.ImageResource(name: "astra", bundle: resourceBundle)

    /// The "cfr" asset catalog image resource.
    static let cfr = DeveloperToolsSupport.ImageResource(name: "cfr", bundle: resourceBundle)

    /// The "interregional" asset catalog image resource.
    static let interregional = DeveloperToolsSupport.ImageResource(name: "interregional", bundle: resourceBundle)

    /// The "regio" asset catalog image resource.
    static let regio = DeveloperToolsSupport.ImageResource(name: "regio", bundle: resourceBundle)

    /// The "softrans" asset catalog image resource.
    static let softrans = DeveloperToolsSupport.ImageResource(name: "softrans", bundle: resourceBundle)

    /// The "tfc" asset catalog image resource.
    static let tfc = DeveloperToolsSupport.ImageResource(name: "tfc", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "astra" asset catalog image.
    static var astra: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .astra)
#else
        .init()
#endif
    }

    /// The "cfr" asset catalog image.
    static var cfr: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .cfr)
#else
        .init()
#endif
    }

    /// The "interregional" asset catalog image.
    static var interregional: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .interregional)
#else
        .init()
#endif
    }

    /// The "regio" asset catalog image.
    static var regio: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .regio)
#else
        .init()
#endif
    }

    /// The "softrans" asset catalog image.
    static var softrans: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .softrans)
#else
        .init()
#endif
    }

    /// The "tfc" asset catalog image.
    static var tfc: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .tfc)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "astra" asset catalog image.
    static var astra: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .astra)
#else
        .init()
#endif
    }

    /// The "cfr" asset catalog image.
    static var cfr: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .cfr)
#else
        .init()
#endif
    }

    /// The "interregional" asset catalog image.
    static var interregional: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .interregional)
#else
        .init()
#endif
    }

    /// The "regio" asset catalog image.
    static var regio: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .regio)
#else
        .init()
#endif
    }

    /// The "softrans" asset catalog image.
    static var softrans: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .softrans)
#else
        .init()
#endif
    }

    /// The "tfc" asset catalog image.
    static var tfc: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .tfc)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

