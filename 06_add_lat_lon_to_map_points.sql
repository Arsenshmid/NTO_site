-- Миграция 06: добавить lat/lon в nto_map_point для настоящей интерактивной карты (Leaflet/OSM).
-- Это дублирует x_pct/y_pct (для старой заглушки-картинки) — не конфликтует.
-- Также добавим object_type, чтобы маркеры могли ссылаться и на НТО, и на МКД.
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

-- Добавим 8 примеров маркеров с РЕАЛЬНЫМИ координатами в Автодорожном округе Якутска,
-- если их ещё нет.
IF NOT EXISTS (SELECT 1 FROM dbo.nto_map_point WHERE lat IS NOT NULL)
BEGIN
    INSERT INTO dbo.nto_map_point (lat, lon, label, color, is_test, object_type, description) VALUES
     (62.0315, 129.7338, N'Центр округа',           'red',    1, 'nto', N'Условный центр Автодорожного округа'),
     (62.0280, 129.7400, N'пр. Ленина, 45 (к/т Лена)', 'blue',   1, 'nto', N'Тестовый маркер — НТО №2'),
     (62.0260, 129.7240, N'ул. Крупской, 13',        'green',  1, 'nto', N'Тестовый маркер — летние навесы'),
     (62.0400, 129.7500, N'пр. Николаева, 40/6',     'orange', 1, 'nto', N'Тестовый маркер — газеты/журналы'),
     (62.0200, 129.7200, N'Сергеляхское шоссе',     'red',    1, 'nto', N'Тестовый маркер — розлив воды'),
     (62.0450, 129.7650, N'ул. Дежнева, 89К',       'blue',   1, 'nto', N'Тестовый маркер — продукты'),
     (62.0150, 129.7100, N'мкр. Марха',              'green',  1, 'nto', N'Граница округа на западе'),
     (62.0600, 129.7800, N'ул. Тимирязева',          'orange', 1, 'nto', N'Северная часть округа');
    PRINT N'Добавлено 8 примеров маркеров с реальными координатами';
END
GO
PRINT N'Миграция 06 завершена.';
