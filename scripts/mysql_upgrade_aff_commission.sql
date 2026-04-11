-- MySQL upgrade for affiliate daily commission
-- Safe to run multiple times.

SET @current_schema := DATABASE();

SET @ddl := (
  SELECT IF(
    EXISTS (
      SELECT 1
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = @current_schema
        AND TABLE_NAME = 'users'
        AND COLUMN_NAME = 'aff_commission_percent'
    ),
    'SELECT ''users.aff_commission_percent already exists'' AS message',
    'ALTER TABLE `users` ADD COLUMN `aff_commission_percent` BIGINT NULL DEFAULT -1'
  )
);
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

UPDATE `users`
SET `aff_commission_percent` = -1
WHERE `aff_commission_percent` IS NULL;

UPDATE `users`
SET `quota` = `quota` + `aff_quota`
WHERE `aff_quota` > 0;

UPDATE `users`
SET `aff_quota` = 0
WHERE `aff_quota` > 0;

INSERT INTO `options` (`key`, `value`)
VALUES ('AffCommissionPercentage', '1')
ON DUPLICATE KEY UPDATE `value` = `value`;

CREATE TABLE IF NOT EXISTS `aff_daily_commission_settlements` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `invitee_id` BIGINT NOT NULL,
  `inviter_id` BIGINT NOT NULL DEFAULT 0,
  `settle_date` VARCHAR(10) NOT NULL,
  `start_timestamp` BIGINT NOT NULL,
  `end_timestamp` BIGINT NOT NULL,
  `consumed_quota` BIGINT NOT NULL DEFAULT 0,
  `commission_percent` BIGINT NOT NULL DEFAULT 0,
  `commission_quota` BIGINT NOT NULL DEFAULT 0,
  `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_aff_daily_invitee_date` (`invitee_id`, `settle_date`),
  KEY `idx_aff_daily_commission_settlements_inviter_id` (`inviter_id`),
  KEY `idx_aff_daily_commission_settlements_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = @current_schema
  AND TABLE_NAME = 'users'
  AND COLUMN_NAME = 'aff_commission_percent';

SELECT `key`, `value`
FROM `options`
WHERE `key` = 'AffCommissionPercentage';

SELECT COUNT(*) AS `pending_aff_quota_users`
FROM `users`
WHERE `aff_quota` > 0;

SHOW TABLES LIKE 'aff_daily_commission_settlements';
