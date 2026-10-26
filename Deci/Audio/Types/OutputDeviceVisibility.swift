// Deci/Audio/Types/OutputDeviceVisibility.swift

/// Which output devices the Mixer popup's picker lists, leaving out the devices the user has hidden.
nonisolated enum OutputDeviceVisibility {
    /// `sorted` (already in priority order) without the hidden devices. The current default output device is always
    /// kept, even if hidden. Falls back to the whole list when the filter leaves nothing: the default's UID can be briefly
    /// nil during a device switchover, and a picker must not show zero rows in that window.
    static func visible(
        sorted: [AudioDevice],
        defaultUID: String?,
        isHidden: (String) -> Bool
    ) -> [AudioDevice] {
        let filtered = sorted.filter { $0.uid == defaultUID || !isHidden($0.uid) }
        return filtered.isEmpty ? sorted : filtered
    }
}
