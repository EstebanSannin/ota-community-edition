-- No-op. Upstream V10 renamed tables out of a separate legacy `device_registry` database
-- into director_v2. On this monolith the device-registry schema is created directly in
-- V9__create_device_registry_schema.sql, so there is nothing to import.
SELECT 1;
