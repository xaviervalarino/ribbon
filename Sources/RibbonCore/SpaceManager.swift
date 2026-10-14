import Foundation
import CoreGraphics

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

public enum SpaceManager {
    public static func currentSpaceID() -> UInt64? {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return nil
        }
        for display in displaySpaces {
            if let current = display["Current Space"] as? [String: Any] {
                if let id = current["ManagedSpaceID"] as? UInt64 {
                    return id
                } else if let id = current["id64"] as? UInt64 {
                    return id
                } else if let id = current["ManagedSpaceID"] as? Int {
                    return UInt64(id)
                } else if let id = current["id64"] as? Int {
                    return UInt64(id)
                }
            }
        }
        return nil
    }

    public static func activeSpaces() -> [UInt64] {
        let cid = defaultConnection()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }
        var result: [UInt64] = []
        for display in displaySpaces {
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            let sID = (current["ManagedSpaceID"] as? UInt64)
                ?? (current["id64"] as? UInt64)
                ?? (current["ManagedSpaceID"] as? Int).map(UInt64.init)
                ?? (current["id64"] as? Int).map(UInt64.init)
            if let sID {
                result.append(sID)
            }
        }
        return result
    }

    public static func space(forWindowID windowID: CGWindowID) -> UInt64? {
        let cid = defaultConnection()
        let array = [windowID] as CFArray
        guard let spaces = CGSCopySpacesForWindows(cid, 0x7, array) as? [UInt64], let first = spaces.first else {
            if let spaces = CGSCopySpacesForWindows(cid, 0x7, array) as? [Int], let first = spaces.first {
                return UInt64(first)
            }
            return nil
        }
        return first
    }
}

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?
