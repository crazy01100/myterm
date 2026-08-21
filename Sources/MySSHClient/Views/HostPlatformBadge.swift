import AppKit
import SwiftUI

struct HostPlatformBadge: View {
    let platform: HostPlatform?
    var size: CGFloat = 42
    var isSelected = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(badgeColor)

            if let platform {
                platformMark(platform)
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.43, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .frame(width: size, height: size)
        .help(platform?.title ?? "尚未辨識平台；連線成功後會自動偵測")
        .accessibilityLabel(platform?.title ?? "尚未辨識平台")
    }

    @ViewBuilder
    private func platformMark(_ platform: HostPlatform) -> some View {
        if let image = PlatformIconLibrary.image(for: platform) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
        } else {
            Text(platform.fallbackMark)
                .font(.system(size: size * 0.31, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var badgeColor: Color {
        guard let platform else { return AppVisualTheme.subtleSurface }
        return platform.badgeColor
    }
}

private enum PlatformIconLibrary {
    private static var cache: [HostPlatform: NSImage] = [:]

    static func image(for platform: HostPlatform) -> NSImage? {
        if let cached = cache[platform] { return cached }
        guard let resourceName = platform.iconResourceName,
              let url = Bundle.main.url(
                  forResource: resourceName,
                  withExtension: "svg",
                  subdirectory: "PlatformIcons"
              ),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[platform] = image
        return image
    }
}

private extension HostPlatform {
    var iconResourceName: String? {
        switch self {
        case .ubuntu: "ubuntu"
        case .debian: "debian"
        case .almaLinux: "almalinux"
        case .rockyLinux: "rockylinux"
        case .centOS: "centos"
        case .redHat: "redhat"
        case .fedora: "fedora"
        case .amazonLinux: nil
        case .alpine: "alpinelinux"
        case .openSUSE: "opensuse"
        case .archLinux: "archlinux"
        case .macOS: "apple"
        case .freeBSD: "freebsd"
        case .cisco: "cisco"
        case .juniper: "junipernetworks"
        case .arista: nil
        case .openWrt: "openwrt"
        }
    }

    var fallbackMark: String {
        switch self {
        case .amazonLinux: "AL"
        case .arista: "A"
        default: String(title.prefix(2)).uppercased()
        }
    }

    var badgeColor: Color {
        switch self {
        case .ubuntu: Color(red: 0.91, green: 0.25, blue: 0.10)
        case .debian: Color(red: 0.84, green: 0.00, blue: 0.29)
        case .almaLinux: Color(red: 0.05, green: 0.39, blue: 0.54)
        case .rockyLinux: Color(red: 0.06, green: 0.48, blue: 0.39)
        case .centOS: Color(red: 0.52, green: 0.28, blue: 0.57)
        case .redHat: Color(red: 0.82, green: 0.06, blue: 0.10)
        case .fedora: Color(red: 0.08, green: 0.29, blue: 0.52)
        case .amazonLinux: Color(red: 0.95, green: 0.56, blue: 0.08)
        case .alpine: Color(red: 0.05, green: 0.52, blue: 0.68)
        case .openSUSE: Color(red: 0.45, green: 0.73, blue: 0.13)
        case .archLinux: Color(red: 0.09, green: 0.58, blue: 0.76)
        case .macOS: Color(red: 0.34, green: 0.36, blue: 0.40)
        case .freeBSD: Color(red: 0.78, green: 0.08, blue: 0.08)
        case .cisco: Color(red: 0.02, green: 0.68, blue: 0.82)
        case .juniper: Color(red: 0.12, green: 0.48, blue: 0.26)
        case .arista: Color(red: 0.12, green: 0.36, blue: 0.66)
        case .openWrt: Color(red: 0.16, green: 0.43, blue: 0.70)
        }
    }
}
