-- Миграция 06: добавить lat/lon в nto_map_point для настоящей интерактивной карты (Leaflet/OSM).
-- Это дублирует x_pct/y_pct (для старой заглушки-картинки) — не конфликтует.
-- Также добавим object_type, чтобы маркеры могли ссылаться и на НТО, и на МКД.
-- ВНИМАНИЕ: INSERT примеров маркеров перенесён в миграцию 07 (там сначала снимается NOT NULL с x_pct/y_pct).
USE NtoDB;
GO
IF COL_LENGTH('dbo.nto_map_point','lat') IS NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ADD lat DECIMAL(9,6) NULL;
    PRINT N'Добавлена колонка lat';
END
GO
IF COL_LENGTH('dbo.nto_map_point','lon') IS NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ADD lon DECIMAL(9,6) NULL;
    PRINT N'Добавлена колонка lon';
END
GO
IF COL_LENGTH('dbo.nto_map_point','object_type') IS NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ADD object_type NVARCHAR(10) NULL DEFAULT 'nto';
    PRINT N'Добавлена колонка object_type';
END
GO
IF COL_LENGTH('dbo.nto_map_point','description') IS NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ADD description NVARCHAR(500) NULL;
    PRINT N'Добавлена колонка description';
END
GO
PRINT N'Миграция 06 завершена. Примеры маркеров добавит миграция 07.';
