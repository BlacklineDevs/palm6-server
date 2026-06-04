-- ============================================================================
-- 0010_properties.sql — properties table for the housing/realty resource
--
-- Stores owned/for-sale properties: location (street/region/coords), shell
-- and apartment identifiers, sale state, price, owner identifier, and JSON
-- blobs for furniture, extra images, and per-key access lists.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `properties` (
  `id` INT AUTO_INCREMENT PRIMARY KEY,
  `owner` VARCHAR(50) DEFAULT NULL,
  `street` VARCHAR(100) DEFAULT NULL,
  `region` VARCHAR(100) DEFAULT NULL,
  `description` TEXT DEFAULT NULL,
  `has_access` LONGTEXT DEFAULT NULL,
  `extra_imgs` LONGTEXT DEFAULT NULL,
  `furnitures` LONGTEXT DEFAULT NULL,
  `for_sale` TINYINT(1) DEFAULT 1,
  `price` INT DEFAULT 0,
  `shell` VARCHAR(50) DEFAULT NULL,
  `apartment` VARCHAR(50) DEFAULT NULL,
  `coords` TEXT DEFAULT NULL,
  INDEX `owner_idx` (`owner`),
  INDEX `apartment_idx` (`apartment`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
