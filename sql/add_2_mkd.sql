/* =====================================================================
   ДОБАВЛЕНИЕ 2 МКД ВРУЧНУЮ ЧЕРЕЗ SSMS (версия 2 — без FullAddress)
   - Красноярова, 43 → УК "Жилищный Стандарт"
   - Матросова, 1/3  → УК "Юнион"

   Выполнять в SSMS при подключении к базе AvtodorDB!
   (В SSMS вверху редактора выберите AvtodorDB, не NtoDB.)

   ЧТО ИСПРАВЛЕНО В ВЕРСИИ 2:
   - Полностью убрал FullAddress из INSERT и UPDATE.
   - В вашей базе FullAddress — ВЫЧИСЛЯЕМЫЙ столбец (Street + ', ' + HouseNo),
     SQL Server запрещает записывать в вычисляемые столбцы (ошибка 271).
     Адрес посчитается автоматически из Street + HouseNo.
   - Если скрипт уже запускали — Красноярова 43 не добавился (INSERT упал).
     Этот скрипт добавит его. Матросова 1/3 уже был — обновит координаты и УК.

   Координаты из OpenStreetMap (Nominatim):
   - Красноярова 43: 62.0138682, 129.7102697 (Автодорожный округ, район Радиоцентр)
   - Матросова 1/3:  62.008387,  129.714697  (из исходного реестра)

   Безопасно для повторного запуска: проверяет, есть ли уже дом, и не дублирует.
   ===================================================================== */
USE AvtodorDB;
GO
SET NOCOUNT ON;
PRINT N'--- Добавление 2 МКД вручную (версия 2, без FullAddress) ---';

-- проверим, что колонки Lat/Lon существуют (миграция 11 выполнена)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Lat')
   OR NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Lon')
BEGIN
  PRINT N'ОШИБКА: колонок Lat/Lon нет в dbo.House. Сначала выполните миграцию 11.';
  RETURN;
END
PRINT N'Колонки Lat/Lon найдены.';

-- проверим и добавим недостающие колонки (идемпотентно)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'UKName')
  ALTER TABLE dbo.House ADD UKName NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsEmergency')
  ALTER TABLE dbo.House ADD IsEmergency BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'HouseType')
  ALTER TABLE dbo.House ADD HouseType NVARCHAR(50) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'HeatingType')
  ALTER TABLE dbo.House ADD HeatingType NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'StatusText')
  ALTER TABLE dbo.House ADD StatusText NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsAuction')
  ALTER TABLE dbo.House ADD IsAuction BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsNoUk')
  ALTER TABLE dbo.House ADD IsNoUk BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsUndefined')
  ALTER TABLE dbo.House ADD IsUndefined BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsEgrnQuery')
  ALTER TABLE dbo.House ADD IsEgrnQuery BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'CoordsApprox')
  ALTER TABLE dbo.House ADD CoordsApprox BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsHiddenFromMap')
  ALTER TABLE dbo.House ADD IsHiddenFromMap BIT NOT NULL DEFAULT 0;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsDemolished')
  ALTER TABLE dbo.House ADD IsDemolished BIT NOT NULL DEFAULT 0;
GO

-- =====================================================================
-- 1) КРАСНОЯРОВА, 43 → УК "Жилищный Стандарт"
-- =====================================================================
PRINT N'';
PRINT N'--- 1) Красноярова, 43 (УК Жилищный Стандарт) ---';

IF NOT EXISTS (
  SELECT 1 FROM dbo.House
  WHERE LTRIM(RTRIM(LOWER(Street))) = N'красноярова'
    AND LTRIM(RTRIM(LOWER(HouseNo))) = N'43'
)
BEGIN
  -- ВАЖНО: FullAddress НЕ указываем — он вычисляемый, посчитается сам
  -- из Street + ', ' + HouseNo
  INSERT INTO dbo.House (Street, HouseNo, Lat, Lon, IsEmergency,
                         HouseType, HeatingType, StatusText, UKName,
                         IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox)
  VALUES (N'Красноярова', N'43',
          62.0138682, 129.7102697, 0,
          N'Каменный', N'Теплоэнергия', N'Действующий', N'УК «Жилищный Стандарт»',
          0, 0, 0, 0, 0);
  PRINT N'  Добавлен дом: Красноярова, 43 (HouseID=' + CAST(@@IDENTITY AS NVARCHAR(10)) + N').';
END
ELSE
BEGIN
  -- дом уже есть — обновим координаты и УК (FullAddress не трогаем!)
  UPDATE dbo.House SET
    Lat = 62.0138682,
    Lon = 129.7102697,
    UKName = N'УК «Жилищный Стандарт»',
    HouseType = COALESCE(HouseType, N'Каменный'),
    HeatingType = COALESCE(HeatingType, N'Теплоэнергия'),
    StatusText = COALESCE(StatusText, N'Действующий')
   WHERE LTRIM(RTRIM(LOWER(Street))) = N'красноярова'
     AND LTRIM(RTRIM(LOWER(HouseNo))) = N'43';
  PRINT N'  Дом уже был — обновлены координаты и УК: Красноярова, 43.';
END
GO

-- =====================================================================
-- 2) МАТРОСОВА, 1/3 → УК "Юнион"
-- =====================================================================
PRINT N'';
PRINT N'--- 2) Матросова, 1/3 (УК Юнион) ---';

IF NOT EXISTS (
  SELECT 1 FROM dbo.House
  WHERE LTRIM(RTRIM(LOWER(Street))) = N'матросова'
    AND LTRIM(RTRIM(LOWER(HouseNo))) = N'1/3'
)
BEGIN
  INSERT INTO dbo.House (Street, HouseNo, Lat, Lon, IsEmergency,
                         HouseType, HeatingType, StatusText, UKName,
                         IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox)
  VALUES (N'Матросова', N'1/3',
          62.008387, 129.714697, 0,
          N'Деревянный', N'Теплоэнергия', N'Действующий', N'УК Юнион',
          0, 0, 0, 0, 0);
  PRINT N'  Добавлен дом: Матросова, 1/3 (HouseID=' + CAST(@@IDENTITY AS NVARCHAR(10)) + N').';
END
ELSE
BEGIN
  UPDATE dbo.House SET
    Lat = COALESCE(Lat, 62.008387),
    Lon = COALESCE(Lon, 129.714697),
    UKName = N'УК Юнион',
    HouseType = COALESCE(HouseType, N'Деревянный'),
    HeatingType = COALESCE(HeatingType, N'Теплоэнергия'),
    StatusText = COALESCE(StatusText, N'Действующий')
   WHERE LTRIM(RTRIM(LOWER(Street))) = N'матросова'
     AND LTRIM(RTRIM(LOWER(HouseNo))) = N'1/3';
  PRINT N'  Дом уже был — обновлены координаты и УК: Матросова, 1/3.';
END
GO

-- =====================================================================
-- 3) ПРИВЯЗКА К УК (по совпадению названия)
-- =====================================================================
PRINT N'';
PRINT N'--- Привязка домов к УК по названию ---';

IF OBJECT_ID(N'dbo.UK') IS NULL
BEGIN
  CREATE TABLE dbo.UK (
    UKID INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(200) NOT NULL UNIQUE,
    HousesCount INT NULL,
    Note NVARCHAR(500) NULL
  );
  PRINT N'Создана таблица dbo.UK.';
END

-- добавим УК если их нет
IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Жилищный Стандарт»')
  INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Жилищный Стандарт»', 0);
IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Юнион')
  INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Юнион', 0);

-- привяжем Красноярова 43
UPDATE h SET h.UKID = u.UKID
 FROM dbo.House h
 JOIN dbo.UK u ON LTRIM(RTRIM(LOWER(h.UKName))) = LTRIM(RTRIM(LOWER(u.Name)))
WHERE LTRIM(RTRIM(LOWER(h.Street))) = N'красноярова'
  AND LTRIM(RTRIM(LOWER(h.HouseNo))) = N'43';
PRINT N'  Красноярова, 43 → привязан к УК «Жилищный Стандарт» (обновлено строк: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + N').';

-- привяжем Матросова 1/3
UPDATE h SET h.UKID = u.UKID
 FROM dbo.House h
 JOIN dbo.UK u ON LTRIM(RTRIM(LOWER(h.UKName))) = LTRIM(RTRIM(LOWER(u.Name)))
WHERE LTRIM(RTRIM(LOWER(h.Street))) = N'матросова'
  AND LTRIM(RTRIM(LOWER(h.HouseNo))) = N'1/3';
PRINT N'  Матросова, 1/3 → привязан к УК Юнион (обновлено строк: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + N').';
GO

-- =====================================================================
-- 4) ИТОГ — показать что получилось
-- =====================================================================
PRINT N'';
PRINT N'--- Итог: добавленные дома ---';
SELECT h.HouseID, h.Street, h.HouseNo, h.FullAddress, h.Lat, h.Lon,
       h.UKName, u.Name AS uk_table_name,
       h.HouseType, h.HeatingType, h.StatusText
  FROM dbo.House h
  LEFT JOIN dbo.UK u ON u.UKID = h.UKID
 WHERE (LTRIM(RTRIM(LOWER(h.Street))) = N'красноярова' AND LTRIM(RTRIM(LOWER(h.HouseNo))) = N'43')
    OR (LTRIM(RTRIM(LOWER(h.Street))) = N'матросова'   AND LTRIM(RTRIM(LOWER(h.HouseNo))) = N'1/3');
GO

PRINT N'';
PRINT N'=== Готово. Оба дома добавлены. Перезапустите сайт (python app.py) и обновите страницу (Ctrl+F5). ===';
