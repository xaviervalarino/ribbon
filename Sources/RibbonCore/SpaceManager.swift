import Foundation
import CoreGraphics
import ColorSync

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

private func defaultConnection() -> Int32 {
    let cid = _CGSDefaultConnection()
    return cid != 0 ? cid : CGSMainConnectionID()
}

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

public enum SpaceManager {
    public static func spaceIDs(for windowID: CGWindowID) -> [UInt64] {
        let cid = defaultConnection()
        let windowArray = [NSNumber(value: windowID)] as CFArray
        guard let cfSpaces = CGSCopySpacesForWindows(cid, 7, windowArray) as? [NSNumber] else {
            return []
        }
        return cfSpaces.map { $0.uint64Value }
    }

    public static func currentSpaceID(forDisplayID displayID: CGDirectDisplayID? = nil) -> UInt64? {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return nil
        }
        if let dID = displayID {
            let isMain = CGDisplayIsMain(dID) != 0
            var uuidStr: String?
            if let cfuuid = CGDisplayCreateUUIDFromDisplayID(dID) {
                uuidStr = CFUUIDCreateString(nil, cfuuid.takeRetainedValue()) as String
            }
            for display in displaySpaces {
                let ident = display["Display Identifier"] as? String
                if (isMain && ident == "Main") || (uuidStr != nil && ident == uuidStr) {
                    if let current = display["Current Space"] as? [String: Any] {
                        return parseSpaceID(from: current)
                    }
                }
            }
        }
        for display in displaySpaces {
            if let current = display["Current Space"] as? [String: Any],
               let sID = parseSpaceID(from: current) {
                return sID
            }
        }
        return nil
    }

    private static func parseSpaceID(from dict: [String: Any]) -> UInt64? {
        return (dict["id64"] as? UInt64)
            ?? (dict["id64"] as? Int).map(UInt64.init)
            ?? (dict["ManagedSpaceID"] as? UInt64)
            ?? (dict["ManagedSpaceID"] as? Int).map(UInt64.init)
    }

    public static func activeSpaces() -> [UInt64] {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }
        var result: [UInt64] = []
        for display in displaySpaces {
            guard let current = display["Current Space"] as? [String: Any],
                  let sID = parseSpaceID(from: current) else { continue }
            result.append(sID)
        }
        return result
    }

    public static func spaceToDisplayIDMapping(activeDisplayIDs: [CGDirectDisplayID] = []) -> [UInt64: CGDirectDisplayID] {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return [:]
        }
        var activeList = activeDisplayIDs
        if activeList.isEmpty {
            let maxDisplays: UInt32 = 16
            var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
            var displayCount: UInt32 = 0
            CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
            activeList = Array(activeDisplays.prefix(Int(displayCount)))
        }

        var uuidToDisplayID: [String: CGDirectDisplayID] = [:]
        var mainDisplayID: CGDirectDisplayID?
        for dID in activeList {
            if CGDisplayIsMain(dID) != 0 {
                mainDisplayID = dID
            }
            if let cfuuid = CGDisplayCreateUUIDFromDisplayID(dID) {
                let uuidStr = CFUUIDCreateString(nil, cfuuid.takeRetainedValue()) as String
                uuidToDisplayID[uuidStr] = dID
            }
        }

        var result: [UInt64: CGDirectDisplayID] = [:]
        for display in displaySpaces {
            let ident = display["Display Identifier"] as? String
            let matchedDID: CGDirectDisplayID?
            if ident == "Main" {
                matchedDID = mainDisplayID
            } else if let ident = ident, let dID = uuidToDisplayID[ident] {
                matchedDID = dID
            } else {
                matchedDID = nil
            }

            guard let dID = matchedDID else { continue }
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for s in spaces {
                    if let sID = parseSpaceID(from: s) {
                        result[sID] = dID
                    }
                }
            }
        }
        return result
    }

    public static func allManagedSpaceIDs() -> Set<UInt64> {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }
        var result = Set<UInt64>()
        for display in displaySpaces {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for s in spaces {
                    if let sID = parseSpaceID(from: s) {
                        result.insert(sID)
                    }
                }
            }
        }
        return result
    }
}
