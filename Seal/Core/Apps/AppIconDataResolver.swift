import Foundation

enum AppIconDataResolver {
    static func iconRelativePaths(for app: AppRecord) -> [String] {
        var paths: [String] = []
        if let preferred = app.preferredIconRelativePath {
            paths.append(preferred)
        }
        if let original = app.iconRelativePath, original != app.preferredIconRelativePath {
            paths.append(original)
        }
        return paths
    }

    static func fillingMissingInstalledIcons(
        in apps: [AppRecord],
        iconDataByAppID: [UUID: Data]
    ) -> [UUID: Data] {
        var result = iconDataByAppID
        let installedAppIDs = Set(apps.filter(\.belongsInInstalledList).map(\.id))

        for replacement in apps
            .filter({ $0.belongsInInstalledList == false && $0.replacesInstalledAppID != nil })
            .sorted(by: { $0.importedAt > $1.importedAt }) {
            guard let installedAppID = replacement.replacesInstalledAppID,
                  installedAppIDs.contains(installedAppID),
                  result[installedAppID] == nil,
                  let iconData = result[replacement.id] else {
                continue
            }
            result[installedAppID] = iconData
        }

        return result
    }
}
