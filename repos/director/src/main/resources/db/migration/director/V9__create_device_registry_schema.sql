-- Device-registry schema, folded directly into director_v2.
--
-- The standalone ota-device-registry service is archived; device-registry is now merged
-- into the director. This migration creates its tables here (materialized from the archived
-- uptane/ota-device-registry migrations V1..V40), replacing the former V9 cross-database
-- views + V10 import, which required a separate legacy `device_registry` database that a
-- fresh monolith install never has.
--
-- Collations are preserved as upstream produced them (Device/DeviceType/TaggedDevice utf8_bin;
-- the rest utf8_unicode_ci) so FK columns match. FK checks are relaxed during creation because
-- some constraints are self/forward-referential.

SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE `DeletedDevice` (
  `namespace` char(200) NOT NULL,
  `device_uuid` char(36) NOT NULL,
  `device_id` varchar(200) NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  PRIMARY KEY (`namespace`,`device_uuid`,`device_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `Device` (
  `namespace` char(200) NOT NULL,
  `uuid` char(36) NOT NULL,
  `device_id` varchar(200) NOT NULL,
  `device_type` smallint(6) NOT NULL,
  `last_seen` datetime(3) DEFAULT NULL,
  `device_name` varchar(200) NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  `activated_at` datetime(3) DEFAULT NULL,
  `device_status` enum('NotSeen','Error','UpToDate','UpdatePending','Outdated') DEFAULT 'NotSeen',
  `notes` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `hibernated` tinyint(1) NOT NULL,
  PRIMARY KEY (`uuid`),
  UNIQUE KEY `namespace` (`namespace`,`device_name`),
  UNIQUE KEY `namespace_2` (`namespace`,`device_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin;
CREATE TABLE `DeviceGroup` (
  `id` char(36) NOT NULL,
  `group_name` varchar(200) NOT NULL,
  `namespace` char(200) NOT NULL,
  `type` enum('static','dynamic') NOT NULL,
  `expression` varchar(255) DEFAULT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`id`),
  UNIQUE KEY `namespace` (`namespace`,`group_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `DeviceHibernationStatus` (
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `previous_status` tinyint(1) NOT NULL,
  `new_status` tinyint(1) NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  KEY `device_uuid` (`device_uuid`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `DeviceInstallationResult` (
  `correlation_id` varchar(256) NOT NULL,
  `result_code` varchar(256) NOT NULL,
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `received_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `installation_report` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`installation_report`)),
  `success` tinyint(1) NOT NULL,
  PRIMARY KEY (`correlation_id`,`device_uuid`),
  KEY `idx_device_device_uuid` (`device_uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `DevicePublicCredentials` (
  `device_uuid` char(36) NOT NULL,
  `public_credentials` longblob NOT NULL,
  `type_credentials` enum('PEM','OAuthClientCredentials') NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`device_uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `DeviceSystem` (
  `uuid` char(36) NOT NULL,
  `system_info` longtext DEFAULT '{}',
  `local_ipv4` char(15) DEFAULT '',
  `mac_address` char(17) DEFAULT '',
  `hostname` varchar(255) DEFAULT '',
  PRIMARY KEY (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `DeviceType` (
  `id` smallint(6) NOT NULL,
  `name` varchar(200) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin;
INSERT INTO `DeviceType` VALUES
(0,'Other'),
(1,'Vehicle');
CREATE TABLE `EcuInstallationResult` (
  `correlation_id` varchar(256) NOT NULL,
  `result_code` varchar(256) NOT NULL,
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `ecu_id` varchar(64) NOT NULL,
  `success` tinyint(1) NOT NULL,
  PRIMARY KEY (`correlation_id`,`device_uuid`,`ecu_id`),
  CONSTRAINT `fk_ecu_report_device_report` FOREIGN KEY (`correlation_id`, `device_uuid`) REFERENCES `DeviceInstallationResult` (`correlation_id`, `device_uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `EcuReplacement` (
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `former_ecu_id` char(64) DEFAULT NULL,
  `former_hardware_id` varchar(200) DEFAULT NULL,
  `current_ecu_id` char(64) DEFAULT NULL,
  `current_hardware_id` varchar(200) DEFAULT NULL,
  `replaced_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `success` tinyint(1) NOT NULL,
  KEY `fk_ecu_replacement_device` (`device_uuid`),
  CONSTRAINT `fk_ecu_replacement_device` FOREIGN KEY (`device_uuid`) REFERENCES `Device` (`uuid`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `EventJournal` (
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `event_id` char(36) NOT NULL,
  `device_time` datetime(3) NOT NULL,
  `event_type_id` varchar(100) NOT NULL,
  `event_type_version` tinyint(3) unsigned NOT NULL,
  `event` longblob NOT NULL,
  `received_at` datetime NOT NULL,
  PRIMARY KEY (`device_uuid`,`event_id`),
  CONSTRAINT `fk_event_device` FOREIGN KEY (`device_uuid`) REFERENCES `Device` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `GroupMembers` (
  `device_uuid` char(36) NOT NULL,
  `group_id` char(36) NOT NULL,
  PRIMARY KEY (`group_id`,`device_uuid`),
  CONSTRAINT `GroupMembers_ibfk_1` FOREIGN KEY (`group_id`) REFERENCES `DeviceGroup` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `IndexedEvents` (
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `event_id` char(36) NOT NULL,
  `correlation_id` varchar(256) NOT NULL,
  `event_type` varchar(256) DEFAULT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`device_uuid`,`event_id`),
  KEY `correlation_id` (`correlation_id`),
  CONSTRAINT `fk_indexed_event` FOREIGN KEY (`device_uuid`, `event_id`) REFERENCES `EventJournal` (`device_uuid`, `event_id`),
  CONSTRAINT `fk_indexed_event_device` FOREIGN KEY (`device_uuid`) REFERENCES `Device` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `IndexedEventsArchive` (
  `device_uuid` char(36) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL,
  `event_id` char(36) NOT NULL,
  `correlation_id` varchar(256) NOT NULL,
  `event_type` varchar(256) DEFAULT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`device_uuid`,`event_id`),
  KEY `correlation_id` (`correlation_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `InstalledPackage` (
  `device_uuid` char(64) NOT NULL,
  `name` varchar(200) NOT NULL,
  `version` varchar(200) NOT NULL,
  `last_modified` datetime NOT NULL,
  PRIMARY KEY (`device_uuid`,`name`,`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `PackageListItem` (
  `namespace` varchar(255) NOT NULL,
  `package_name` varchar(200) NOT NULL,
  `package_version` varchar(200) NOT NULL,
  `comment` text NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`namespace`,`package_name`,`package_version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
CREATE TABLE `TaggedDevice` (
  `namespace` varchar(255) NOT NULL,
  `device_uuid` char(36) NOT NULL,
  `tag_id` varchar(50) NOT NULL,
  `tag_value` varchar(50) NOT NULL,
  `created_at` datetime(3) NOT NULL DEFAULT current_timestamp(3),
  `updated_at` datetime(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE current_timestamp(3),
  PRIMARY KEY (`device_uuid`,`tag_id`),
  KEY `tag_id` (`tag_id`),
  CONSTRAINT `fk_device_uuid` FOREIGN KEY (`device_uuid`) REFERENCES `Device` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin;

SET FOREIGN_KEY_CHECKS = 1;

-- Auto-record hibernation transitions (device-registry V40). Single-statement trigger.
CREATE TRIGGER device_hibernate_status_update AFTER UPDATE ON Device
  FOR EACH ROW
  INSERT INTO DeviceHibernationStatus (device_uuid, previous_status, new_status)
  VALUES (NEW.uuid, OLD.hibernated, NEW.hibernated)
;
