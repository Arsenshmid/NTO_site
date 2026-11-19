-- Миграция 08: заменить тестовые заглушки на РЕАЛЬНЫЕ точки НТО с координатами.
-- Координаты получены геокодированием адресов из «здесь ИНН по НТО.xlsx» через
-- Nominatim (OpenStreetMap) и проверены на попадание в границы Автодорожного округа.
-- Точка связывается с НТО через object_id (ищем по scheme_num).
USE NtoDB;
GO

-- 1) Удаляем старые тестовые заглушки с координатами (из миграции 07)
DELETE FROM dbo.nto_map_point WHERE is_test = 1;
PRINT N'Удалены старые тестовые заглушки';

-- 2) Вставляем реальные НТО (координаты из OpenStreetMap, внутри границ округа)
-- НТО №3: Дежнева, 89К (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.011836, 129.695826, N'№3 Дежнева, 89К — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'3' AND is_deleted = 0;

-- НТО №4: Тимирязева, 51В (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.005438, 129.713370, N'№4 Тимирязева, 51В — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'4' AND is_deleted = 0;

-- НТО №5: Тимирязева, 53А (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.004830, 129.713925, N'№5 Тимирязева, 53А — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'5' AND is_deleted = 0;

-- НТО №8: Красильникова, 2/1 (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.002774, 129.679374, N'№8 Красильникова, 2/1 — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'8' AND is_deleted = 0;

-- НТО №9: Пр. М-Николаева, 26 (Розлив воды)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 61.993228, 129.683723, N'№9 Пр. М-Николаева, 26 — Розлив воды', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'9' AND is_deleted = 0;

-- НТО №12: Пр. М-Николаева, 40 (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 61.982045, 129.661924, N'№12 Пр. М-Николаева, 40 — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'12' AND is_deleted = 0;

-- НТО №20: Ленина, 47 (Продукты)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.019723, 129.721537, N'№20 Ленина, 47 — Продукты', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'20' AND is_deleted = 0;

-- НТО №39: Крупская, 19 (Цветы)
INSERT INTO dbo.nto_map_point (object_id, lat, lon, label, color, is_test, object_type, description)
SELECT id, 62.020122, 129.718671, N'№39 Крупская, 19 — Цветы', 'blue', 0, 'nto', N'Павильон. Источник: здесь ИНН по НТО.xlsx'
FROM dbo.nto_object WHERE scheme_num = N'39' AND is_deleted = 0;

PRINT N'Добавлено 8 реальных точек НТО (из Excel, геокодировано через OpenStreetMap)';

-- 3) Запишем координаты и в сами НТО (чтобы они попадали в /api/map_markers как НТО)
UPDATE dbo.nto_object SET lat = 62.011836, lon = 129.695826 WHERE scheme_num = N'3'  AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 62.005438, lon = 129.713370 WHERE scheme_num = N'4'  AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 62.004830, lon = 129.713925 WHERE scheme_num = N'5'  AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 62.002774, lon = 129.679374 WHERE scheme_num = N'8'  AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 61.993228, lon = 129.683723 WHERE scheme_num = N'9'  AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 61.982045, lon = 129.661924 WHERE scheme_num = N'12' AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 62.019723, lon = 129.721537 WHERE scheme_num = N'20' AND is_deleted = 0 AND lat IS NULL;
UPDATE dbo.nto_object SET lat = 62.020122, lon = 129.718671 WHERE scheme_num = N'39' AND is_deleted = 0 AND lat IS NULL;
PRINT N'Координаты записаны и в карточки НТО';

GO
PRINT N'Миграция 08 завершена.';
