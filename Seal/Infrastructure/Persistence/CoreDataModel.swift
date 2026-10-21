import CoreData

enum CoreDataModel {
    static let appEntityName = "AppEntity"
    static let extensionEntityName = "ExtensionEntity"

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let app = NSEntityDescription()
        app.name = appEntityName
        app.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        app.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("name", type: .stringAttributeType),
            attribute("version", type: .stringAttributeType),
            attribute("buildNumber", type: .stringAttributeType),
            attribute("size", type: .integer64AttributeType),
            attribute("iconRelativePath", type: .stringAttributeType, optional: true),
            attribute("stateRaw", type: .stringAttributeType),
            attribute("expiryDate", type: .dateAttributeType, optional: true),
            attribute("accountID", type: .UUIDAttributeType, optional: true),
            attribute("signingTeamID", type: .stringAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true),
            attribute("signedDeviceIdentifier", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileCreationDate", type: .dateAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("entitlementValidationStatus", type: .stringAttributeType, optional: true),
            attribute("capabilityValidationStatus", type: .stringAttributeType, optional: true),
            attribute("lastSignedAt", type: .dateAttributeType, optional: true),
            attribute("lastInstalledAt", type: .dateAttributeType, optional: true),
            attribute("removedExtensionBundleIdentifiersData", type: .binaryDataAttributeType, optional: true),
            attribute("signingTargetsData", type: .binaryDataAttributeType, optional: true),
            attribute("pendingSignedSnapshotData", type: .binaryDataAttributeType, optional: true),
            attribute("ipaRelativePath", type: .stringAttributeType),
            attribute("signedIPARelativePath", type: .stringAttributeType, optional: true),
            attribute("signedIPASHA256", type: .stringAttributeType, optional: true),
            attribute("signedArtifactStatusRaw", type: .stringAttributeType, optional: true),
            attribute("installedAppMarkerVersion", type: .integer64AttributeType, optional: true),
            attribute("preferredBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("preferredDisplayName", type: .stringAttributeType, optional: true),
            attribute("preferredIconRelativePath", type: .stringAttributeType, optional: true),
            attribute("lastInstallFailureCode", type: .stringAttributeType, optional: true),
            attribute("lastInstallFailureReason", type: .stringAttributeType, optional: true),
            attribute("pendingFileTransactionID", type: .UUIDAttributeType, optional: true),
            attribute("hasPendingSelfUpdateSource", type: .booleanAttributeType, defaultValue: false),
            attribute("pendingUpdateSourceFingerprint", type: .stringAttributeType, optional: true),
            attribute("installedFingerprint", type: .stringAttributeType, optional: true),
            attribute("needsIPAImport", type: .booleanAttributeType, defaultValue: false),
            attribute("importWarningsData", type: .binaryDataAttributeType, optional: true),
            attribute("replacesInstalledAppID", type: .UUIDAttributeType, optional: true),
            attribute("isSeal", type: .booleanAttributeType, defaultValue: false),
            attribute("isPinned", type: .booleanAttributeType, defaultValue: false),
            attribute("extensionProfileStrategyRaw", type: .stringAttributeType, optional: true),
            attribute("importedAt", type: .dateAttributeType)
        ]

        let appExtension = NSEntityDescription()
        appExtension.name = extensionEntityName
        appExtension.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        appExtension.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("kindRaw", type: .stringAttributeType),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true)
        ]

        addRelationships(app: app, appExtension: appExtension)
        model.entities = [app, appExtension]
        return model
    }

    /// Store schema before recovery metadata was persisted.
    static func makeLegacyV5() -> NSManagedObjectModel {
        let model = make()
        if let app = model.entitiesByName[appEntityName] {
            app.properties = app.properties.filter {
                !["installedFingerprint", "needsIPAImport", "importWarningsData"].contains($0.name)
            }
        }
        return model
    }

    /// Previous current schema, before per-App uninstall markers were persisted.
    static func makeLegacyV4() -> NSManagedObjectModel {
        let model = makeLegacyV5()
        if let app = model.entitiesByName[appEntityName] {
            app.properties = app.properties.filter { $0.name != "installedAppMarkerVersion" }
        }
        return model
    }

    /// 0.1.32 schema before pending signed snapshots became persistent.
    static func makeLegacyV3() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let app = NSEntityDescription()
        app.name = appEntityName
        app.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        app.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("name", type: .stringAttributeType),
            attribute("version", type: .stringAttributeType),
            attribute("buildNumber", type: .stringAttributeType),
            attribute("size", type: .integer64AttributeType),
            attribute("iconRelativePath", type: .stringAttributeType, optional: true),
            attribute("stateRaw", type: .stringAttributeType),
            attribute("expiryDate", type: .dateAttributeType, optional: true),
            attribute("accountID", type: .UUIDAttributeType, optional: true),
            attribute("signingTeamID", type: .stringAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true),
            attribute("signedDeviceIdentifier", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileCreationDate", type: .dateAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("entitlementValidationStatus", type: .stringAttributeType, optional: true),
            attribute("capabilityValidationStatus", type: .stringAttributeType, optional: true),
            attribute("lastSignedAt", type: .dateAttributeType, optional: true),
            attribute("lastInstalledAt", type: .dateAttributeType, optional: true),
            attribute("removedExtensionBundleIdentifiersData", type: .binaryDataAttributeType, optional: true),
            attribute("signingTargetsData", type: .binaryDataAttributeType, optional: true),
            attribute("ipaRelativePath", type: .stringAttributeType),
            attribute("signedIPARelativePath", type: .stringAttributeType, optional: true),
            attribute("signedIPASHA256", type: .stringAttributeType, optional: true),
            attribute("signedArtifactStatusRaw", type: .stringAttributeType, optional: true),
            attribute("preferredBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("preferredDisplayName", type: .stringAttributeType, optional: true),
            attribute("preferredIconRelativePath", type: .stringAttributeType, optional: true),
            attribute("lastInstallFailureCode", type: .stringAttributeType, optional: true),
            attribute("lastInstallFailureReason", type: .stringAttributeType, optional: true),
            attribute("pendingFileTransactionID", type: .UUIDAttributeType, optional: true),
            attribute("hasPendingSelfUpdateSource", type: .booleanAttributeType, defaultValue: false),
            attribute("pendingUpdateSourceFingerprint", type: .stringAttributeType, optional: true),
            attribute("replacesInstalledAppID", type: .UUIDAttributeType, optional: true),
            attribute("isSeal", type: .booleanAttributeType, defaultValue: false),
            attribute("isPinned", type: .booleanAttributeType, defaultValue: false),
            attribute("extensionProfileStrategyRaw", type: .stringAttributeType, optional: true),
            attribute("importedAt", type: .dateAttributeType)
        ]

        let appExtension = NSEntityDescription()
        appExtension.name = extensionEntityName
        appExtension.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        appExtension.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("kindRaw", type: .stringAttributeType),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true)
        ]

        addRelationships(app: app, appExtension: appExtension)
        model.entities = [app, appExtension]
        return model
    }

    static func makeLegacyV2() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let app = NSEntityDescription()
        app.name = appEntityName
        app.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        app.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("name", type: .stringAttributeType),
            attribute("version", type: .stringAttributeType),
            attribute("buildNumber", type: .stringAttributeType),
            attribute("size", type: .integer64AttributeType),
            attribute("iconRelativePath", type: .stringAttributeType, optional: true),
            attribute("stateRaw", type: .stringAttributeType),
            attribute("expiryDate", type: .dateAttributeType, optional: true),
            attribute("accountID", type: .UUIDAttributeType, optional: true),
            attribute("signingTeamID", type: .stringAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true),
            attribute("signedDeviceIdentifier", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileCreationDate", type: .dateAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("entitlementValidationStatus", type: .stringAttributeType, optional: true),
            attribute("capabilityValidationStatus", type: .stringAttributeType, optional: true),
            attribute("lastSignedAt", type: .dateAttributeType, optional: true),
            attribute("lastInstalledAt", type: .dateAttributeType, optional: true),
            attribute("removedExtensionBundleIdentifiersData", type: .binaryDataAttributeType, optional: true),
            attribute("signingTargetsData", type: .binaryDataAttributeType, optional: true),
            attribute("ipaRelativePath", type: .stringAttributeType),
            attribute("signedIPARelativePath", type: .stringAttributeType, optional: true),
            attribute("preferredBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("isSeal", type: .booleanAttributeType, defaultValue: false),
            attribute("isPinned", type: .booleanAttributeType, defaultValue: false),
            attribute("importedAt", type: .dateAttributeType)
        ]

        let appExtension = NSEntityDescription()
        appExtension.name = extensionEntityName
        appExtension.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        appExtension.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("kindRaw", type: .stringAttributeType),
            attribute("provisioningProfileUUID", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileName", type: .stringAttributeType, optional: true),
            attribute("provisioningProfileExpirationDate", type: .dateAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true)
        ]

        addRelationships(app: app, appExtension: appExtension)
        model.entities = [app, appExtension]
        return model
    }


    static func makeLegacyV1() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let app = NSEntityDescription()
        app.name = appEntityName
        app.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        app.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("name", type: .stringAttributeType),
            attribute("version", type: .stringAttributeType),
            attribute("buildNumber", type: .stringAttributeType),
            attribute("size", type: .integer64AttributeType),
            attribute("iconRelativePath", type: .stringAttributeType, optional: true),
            attribute("stateRaw", type: .stringAttributeType),
            attribute("expiryDate", type: .dateAttributeType, optional: true),
            attribute("accountID", type: .UUIDAttributeType, optional: true),
            attribute("certificateSerialNumber", type: .stringAttributeType, optional: true),
            attribute("ipaRelativePath", type: .stringAttributeType),
            attribute("signedIPARelativePath", type: .stringAttributeType, optional: true),
            attribute("preferredBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("isSeal", type: .booleanAttributeType, defaultValue: false),
            attribute("isPinned", type: .booleanAttributeType, defaultValue: false),
            attribute("importedAt", type: .dateAttributeType)
        ]

        let appExtension = NSEntityDescription()
        appExtension.name = extensionEntityName
        appExtension.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        appExtension.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("originalBundleIdentifier", type: .stringAttributeType),
            attribute("mappedBundleIdentifier", type: .stringAttributeType, optional: true),
            attribute("kindRaw", type: .stringAttributeType)
        ]

        addRelationships(app: app, appExtension: appExtension)
        model.entities = [app, appExtension]
        return model
    }


    private static func addRelationships(
        app: NSEntityDescription,
        appExtension: NSEntityDescription
    ) {
        let extensionsRelationship = NSRelationshipDescription()
        extensionsRelationship.name = "extensions"
        extensionsRelationship.destinationEntity = appExtension
        extensionsRelationship.minCount = 0
        extensionsRelationship.maxCount = 0
        extensionsRelationship.deleteRule = .cascadeDeleteRule
        extensionsRelationship.isOptional = true

        let appRelationship = NSRelationshipDescription()
        appRelationship.name = "app"
        appRelationship.destinationEntity = app
        appRelationship.minCount = 0
        appRelationship.maxCount = 1
        appRelationship.deleteRule = .nullifyDeleteRule
        appRelationship.isOptional = true

        extensionsRelationship.inverseRelationship = appRelationship
        appRelationship.inverseRelationship = extensionsRelationship
        app.properties.append(extensionsRelationship)
        appExtension.properties.append(appRelationship)
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        return attribute
    }
}
