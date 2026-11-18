-- Миграция 03: создать таблицу точек на карте (для заглушки карты Автодорожного округа)
-- Точки хранят позицию на ИЗОБРАЖЕНИИ карты (в процентах 0..100 по X и Y), чтобы
-- не зависеть от реальных координат. Связь с НТО — по object_id (необязательно).
USE NtoDB;
GO
IF OBJECT_ID(N'dbo.nto_map_point') IS NULL
BEGIN
    CREATE TABLE dbo.nto_map_point (
        id          INT IDENTITY(1,1) PRIMARY KEY,
        object_id   INT NULL REFERENCES dbo.nto_object(id),  -- связь с НТО (может быть пусто — просто метка)
        x_pct       DECIMAL(5,2) NOT NULL,                   -- позиция X на картинке, 0..100
        y_pct       DECIMAL(5,2) NOT NULL,                   -- позиция Y на картинке, 0..100
        label       NVARCHAR(200) NULL,                      -- подпись точки
        color       NVARCHAR(20)  NULL DEFAULT 'red',        -- цвет маркера (red, green, blue, orange)
        is_test     BIT NOT NULL DEFAULT 1,                  -- 1 = тестовая точка-заглушка, 0 = настоящая
        created_at  DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        updated_at  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
    );
    PRINT N'Создана таблица nto_map_point';
END
GO
-- Вставим 5 тестовых точек-заглушек, если таблица пустая
IF NOT EXISTS (SELECT 1 FROM dbo.nto_map_point)
BEGIN
    INSERT INTO dbo.nto_map_point (x_pct, y_pct, label, color, is_test) VALUES
        (28.5, 60.0, N'Тест: пр. Ленина (заглушка)', 'red', 1),
        (35.0, 45.0, N'Тест: Крупской (заглушка)', 'blue', 1),
        (42.0, 55.0, N'Тест: Николаева (заглушка)', 'green', 1),
        (50.0, 70.0, N'Тест: Новая точка (заглушка)', 'orange', 1),
        (22.0, 35.0, N'Тест: Север (заглушка)', 'red', 1);
    PRINT N'Добавлены 5 тестовых точек-заглушек';
END
GO
PRINT N'Миграция 03 завершена.';
