import Foundation

struct HostPlatformDetector {
    private var buffer = ""
    private var detected = false

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> HostPlatform? {
        guard !detected else { return nil }
        buffer += String(decoding: bytes, as: UTF8.self).lowercased()
        if buffer.count > 32_768 { buffer.removeFirst(buffer.count - 32_768) }

        let platform: HostPlatform?
        if containsAny("ubuntu ", "ubuntu linux", "ubuntu release", "id=ubuntu") { platform = .ubuntu }
        else if containsAny("debian gnu/linux", "debian release", "id=debian") { platform = .debian }
        else if containsAny("almalinux", "almalinux-release") { platform = .almaLinux }
        else if containsAny("rocky linux", "rocky-release") { platform = .rockyLinux }
        else if containsAny("centos linux", "centos-release") { platform = .centOS }
        else if containsAny("red hat enterprise linux", "redhat-release", "rhel ") { platform = .redHat }
        else if containsAny("fedora linux", "fedora release") { platform = .fedora }
        else if containsAny("amazon linux", "amzn") { platform = .amazonLinux }
        else if containsAny("alpine linux", "alpine-release") { platform = .alpine }
        else if containsAny("opensuse", "suse linux enterprise") { platform = .openSUSE }
        else if containsAny("arch linux", "archlinux") { platform = .archLinux }
        else if containsAny("darwin kernel version", "darwin ", "macos ") { platform = .macOS }
        else if containsAny("freebsd ", "freebsd/") { platform = .freeBSD }
        else if containsAny("cisco ios", "cisco nx-os", "ios xe software") { platform = .cisco }
        else if containsAny("junos ", "juniper networks") { platform = .juniper }
        else if containsAny("arista networks eos", "arista eos") { platform = .arista }
        else if containsAny("openwrt", "openwrt release") { platform = .openWrt }
        else { platform = nil }

        if platform != nil { detected = true }
        return platform
    }

    private func containsAny(_ needles: String...) -> Bool {
        needles.contains { buffer.contains($0) }
    }
}
