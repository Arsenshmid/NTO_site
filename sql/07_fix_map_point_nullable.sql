-- Миграция 07: исправление проблемы с NOT NULL в nto_map_point.
-- В миграции 03 колонки x_pct и y_pct были NOT NULL, но для новой Leaflet-карты
-- они не нужны (используются lat/lon). Снимаем NOT NULL.
USE NtoDB;
GO

-- Снимаем NOT NULL с x_pct (если ещё стоит)
IF COL_LENGTH('dbo.nto_map_point','x_pct') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ALTER COLUMN x_pct DECIMAL(5,2) NULL;
    PRINT N'Снято NOT NULL с x_pct';
END
GO

-- Снимаем NOT NULL с y_pct
IF COL_LENGTH('dbo.nto_map_point','y_pct') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_map_point ALTER COLUMN y_pct DECIMAL(5,2) NULL;
    PRINT N'Снято NOT NULL с y_pct';
END
GO

-- Проверим, есть ли примеры маркеров с lat/lon (если миграция 06 не смогла их добавить)
IF NOT EXISTS (SELECT 1 FROM dbo.nto_map_point WHERE lat IS NOT NULL)
BEGIN
    -- Добавим 8 примеров маркеров с РЕАЛЬНЫМИ координатами в Автодорожном округе Якутска
    INSERT INTO dbo.nto_map_point (lat, lon, label, color, is_test, object_type, description) VALUES
     (62.0315, 129.7338, N'Центр округа',           'red',    1, 'nto', N'Условный центр Автодорожного округа'),
     (62.0280, 129.7400, N'пр. Ленина, 45 (к/т Лена)', 'blue',   1, 'nto', N'Тестовый маркер — НТО №2'),
     (62.0260, 129.7240, N'ул. Крупской, 13',        'green',  1, 'nto', N'Тестовый маркер — летние навесы'),
     (62.0400, 129.7500, N'пр. Николаева, 40/6',     'orange', 1, 'nto', N'Тестовый маркер — газеты/журналы'),
     (62.0200, 129.7200, N'Сергеляхское шоссе',     'red',    1, 'nto', N'Тестовый маркер — розлив воды'),
     (62.0450, 129.7650, N'ул. Дежнева, 89К',       'blue',   1, 'nto', N'Тестовый маркер — продукты'),
     (62.0150, 129.7100, N'мкр. Марха',              'green',  1, 'nto', N'Граница округа на западе'),
     (62.0600, 129.7800, N'ул. Тимирязева',          'orange', 1, 'nto', N'Северная часть округа');
    PRINT N'Добавлено 8 примеров маркеров (миграция 07)';
END
GO
PRINT N'Миграция 07 завершена.';
