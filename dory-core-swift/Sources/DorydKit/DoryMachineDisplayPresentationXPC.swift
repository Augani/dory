import DoryOperations
import Foundation

enum DoryMachineDisplayPresentationXPCError: Error, Equatable {
    case invalidShape
}

extension DoryMachineDisplayPresentation {
    init(xpcDictionary dictionary: NSDictionary) throws {
        guard Set(dictionary.allKeys.compactMap { $0 as? String })
                == ["schemaVersion", "assignments"],
              dictionary.allKeys.count == 2,
              let schema = dictionary["schemaVersion"] as? NSNumber,
              String(cString: schema.objCType) != "c",
              schema.intValue == Self.currentSchemaVersion,
              let rows = dictionary["assignments"] as? NSArray else {
            throw DoryMachineDisplayPresentationXPCError.invalidShape
        }
        var assignments: [DoryGuestDisplayPresentationAssignment] = []
        assignments.reserveCapacity(rows.count)
        for encoded in rows {
            guard let row = encoded as? NSDictionary,
                  let guestDisplayID = row["guestDisplayID"] as? String,
                  let rawMode = row["mode"] as? String,
                  let mode = DoryGuestDisplayPresentationMode(rawValue: rawMode) else {
                throw DoryMachineDisplayPresentationXPCError.invalidShape
            }
            let expectedKeys: Set<String> = mode == .dedicatedFullscreen
                ? ["guestDisplayID", "mode", "hostDisplayUUID"]
                : ["guestDisplayID", "mode"]
            guard Set(row.allKeys.compactMap { $0 as? String }) == expectedKeys,
                  row.allKeys.count == expectedKeys.count else {
                throw DoryMachineDisplayPresentationXPCError.invalidShape
            }
            let assignment = DoryGuestDisplayPresentationAssignment(
                guestDisplayID: guestDisplayID,
                mode: mode,
                hostDisplayUUID: row["hostDisplayUUID"] as? String
            )
            guard assignment.isValid else {
                throw DoryMachineDisplayPresentationXPCError.invalidShape
            }
            assignments.append(assignment)
        }
        let presentation = DoryMachineDisplayPresentation(
            schemaVersion: schema.intValue,
            assignments: assignments
        )
        guard presentation.isValid else {
            throw DoryMachineDisplayPresentationXPCError.invalidShape
        }
        self = presentation.canonicalized
    }

    var xpcDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "assignments": assignments.map { assignment -> NSDictionary in
                var row: [String: Any] = [
                    "guestDisplayID": assignment.guestDisplayID,
                    "mode": assignment.mode.rawValue,
                ]
                if let hostDisplayUUID = assignment.hostDisplayUUID {
                    row["hostDisplayUUID"] = hostDisplayUUID
                }
                return row as NSDictionary
            } as NSArray,
        ]
    }
}
