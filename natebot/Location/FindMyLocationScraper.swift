import Cocoa

// MARK: - DeviceLocation

struct DeviceLocation {
    let name: String        // e.g. "iPhone"
    let address: String     // e.g. "267 E 700 North St, Provo, UT 84606"
    let timeAgo: String     // e.g. "Now", "3 hr. ago"
    let scrapedAt: Date
}

// MARK: - FindMyLocationScraper

/// Reads device locations from the Find My app via macOS Accessibility API.
/// Requires: Find My running, Accessibility permission granted for this process.
class FindMyLocationScraper {

    /// Scrape all device locations currently shown in Find My's device list.
    func scrapeDeviceLocations() -> [DeviceLocation] {
        let findMyApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.findmy")
        guard let app = findMyApps.first else {
            print("[FindMyScraper] Find My is not running.")
            return []
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var descriptions: [String] = []
        collectDescriptions(appElement, into: &descriptions, depth: 0, maxDepth: 20)

        return parseDescriptions(descriptions)
    }

    // MARK: - Parse descriptions into DeviceLocation array

    private func parseDescriptions(_ descriptions: [String]) -> [DeviceLocation] {
        let now = Date()
        var devices: [DeviceLocation] = []

        for desc in descriptions {
            let parts = desc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }

            let name = parts[0]

            if desc.hasSuffix("Map pin") { continue }

            if desc.contains("No location found") {
                devices.append(DeviceLocation(name: name, address: "No location found", timeAgo: "", scrapedAt: now))
                continue
            }

            guard parts.count >= 3 else { continue }

            var timeAgo = ""
            var addressParts: [String] = []

            for i in 1..<parts.count {
                let p = parts[i]
                if p == "Now" || p == "Paused" || p.contains("hr.") || p.contains("min.") || p.contains("ago") {
                    timeAgo = p
                } else if p.hasSuffix("mi") || p == "0 mi" || (p.count <= 3 && Double(p) != nil) {
                    continue
                } else if p == "This Mac" || p == "With You" {
                    continue
                } else {
                    addressParts.append(p)
                }
            }

            let address = addressParts.joined(separator: ", ").trimmingCharacters(in: .whitespaces)

            if address.isEmpty && !timeAgo.isEmpty {
                devices.append(DeviceLocation(name: name, address: "No location found", timeAgo: timeAgo, scrapedAt: now))
                continue
            }
            guard !address.isEmpty else { continue }

            devices.append(DeviceLocation(name: name, address: address, timeAgo: timeAgo, scrapedAt: now))
        }

        return devices
    }

    // MARK: - AX Tree Walker

    private func collectDescriptions(_ element: AXUIElement, into results: inout [String], depth: Int, maxDepth: Int) {
        if depth > maxDepth { return }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role)
        let roleStr = (role as? String) ?? ""

        var desc: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXDescription" as CFString, &desc)
        let descStr = (desc as? String) ?? ""

        // We want AXStaticText descriptions from the sidebar device list
        if roleStr == "AXStaticText" && !descStr.isEmpty {
            results.append(descStr)
        }

        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children)
        if let kids = children as? [AXUIElement] {
            for kid in kids {
                collectDescriptions(kid, into: &results, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }
}
