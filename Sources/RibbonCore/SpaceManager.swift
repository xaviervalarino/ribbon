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

public enum SpaceManager {
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
}
