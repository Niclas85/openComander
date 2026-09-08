// SPDX-License-Identifier: MIT

import Foundation

public struct NTFSVolumeInspection: Equatable {
    public let information: NTFSVolumeInformation
    public let backupBootSectorMatches: Bool
    public let mftMirrorMatches: Bool
    public let hibernationState: NTFSHibernationState
    public let safetyState: NTFSVolumeSafetyState
}

public enum NTFSVolumeSafetyInspector {
    public static func inspect(
        volume: NTFSVolumeReader,
        userEnabledExperimentalWrites: Bool
    ) throws -> NTFSVolumeInspection {
        let hibernationState = try volume.hibernationState()
        return try inspect(
            volume: volume,
            hibernationState: hibernationState,
            userEnabledExperimentalWrites: userEnabledExperimentalWrites
        )
    }

    /// Compatibility overload for callers that already obtained hibernation state by another
    /// trusted mechanism. New code should use the automatic inspection overload above.
    public static func inspect(
        volume: NTFSVolumeReader,
        isHibernated: Bool,
        userEnabledExperimentalWrites: Bool
    ) throws -> NTFSVolumeInspection {
        try inspect(
            volume: volume,
            hibernationState: isHibernated ? .active : .inactive,
            userEnabledExperimentalWrites: userEnabledExperimentalWrites
        )
    }

    private static func inspect(
        volume: NTFSVolumeReader,
        hibernationState: NTFSHibernationState,
        userEnabledExperimentalWrites: Bool
    ) throws -> NTFSVolumeInspection {
        let information = try volume.volumeInformation()
        let backupMatches = try volume.bootSectorBackupMatches()
        let mirrorMatches = try volume.mftMirrorRecordZeroMatches()
        let supportedVersion = information.majorVersion == 3 && information.minorVersion <= 1
        let unsupportedFlags = information.flags & ~UInt16(0x0001)
        let checksCompleted = backupMatches && mirrorMatches && supportedVersion
        let state = NTFSVolumeSafetyState(
            isDirty: information.isDirty,
            isHibernated: hibernationState == .active || hibernationState == .unknown,
            hasUnsupportedFeatures: !supportedVersion || unsupportedFlags != 0,
            checkCompleted: checksCompleted,
            userEnabledExperimentalWrites: userEnabledExperimentalWrites
        )
        return NTFSVolumeInspection(
            information: information,
            backupBootSectorMatches: backupMatches,
            mftMirrorMatches: mirrorMatches,
            hibernationState: hibernationState,
            safetyState: state
        )
    }
}
