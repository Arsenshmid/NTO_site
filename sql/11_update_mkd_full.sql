/* =====================================================================
   МИГРАЦИЯ 11: полное обновление базы AvtodorDB из реальных Excel-файлов
   коллеги (Реестр МКД 19.11.2026, реестр аварийных, Реестр УК 28.11.2025).

   Выполнять в SSMS при подключении к базе AvtodorDB!
   (Это обновление БАЗЫ МКД, а не NtoDB.)

   Что делает:
   1) Расширяет таблицу dbo.House: добавляет колонки Lat, Lon, IsEmergency,
      IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled,
      Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType,
      StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery,
      CoordsApprox, UKName.
   2) Загружает все дома с координатами во временную таблицу #Staging
      (пачками по 50 — это надёжный синтаксис INSERT VALUES).
   3) Обновляет существующие дома одним UPDATE (по совпадению Street+HouseNo):
      координаты, аварийность, даты сноса, программа переселения,
      распоряжение, тип дома, отопление, привязку к УК, теги.
   4) Вставляет новые дома (которых ещё нет в AvtodorDB.House) одним INSERT.
   5) Помечает снесённые дома (IsDemolished = 1) — остаются в базе,
      но на карте не показываются.
   6) Синхронизирует справочник УК: добавляет новые УК, обновляет кол-во домов.
   7) Привязывает House.UKID к dbo.UK по совпадению названия УК.

   ИСПОЛЬЗУЕТ временные таблицы #Staging вместо MERGE — MERGE в SQL Server
   капризен: несколько MERGE подряд в одном батче вызывают ошибку 156
   «Неправильный синтаксис около ключевого слова WHEN».

   Безопасна для повторного запуска: все операции идемпотентны
   (UPDATE не создаёт дублей, INSERT только недостающие записи).

   Источники данных:
   - Реестр МКД (19.11.2026) недороботанная.xlsx — 463 дома по 32 УК
   - реестр аварийных.xlsx — 147 аварийных домов с распоряжениями и сроками сноса
   - Реестр УК мкд (актуальный) 28.11.2025.xlsx — детализация аварийных (140),
     аукцион (23), без УК (70), неопределённые (16), запрос ЕГРН (14)

   Сгенерировано: 2026-11-20.
   ===================================================================== */
USE AvtodorDB;
GO
SET NOCOUNT ON;
PRINT N'Начата миграция 11 (полное обновление МКД из Excel)...';

/* =====================================================================
   ЧАСТЬ A: структурные изменения (ALTER TABLE).
   Выполняются БЕЗ транзакции — каждое ALTER отдельно.
   Это безопасно: IF NOT EXISTS гарантирует идемпотентность
   (повторный запуск не падает и не дублирует колонки).
   ЗАЧЕМ ДЕЛИТЬ: SQL Server компилирует весь батч до выполнения.
   Если в одном батче и ALTER TABLE ADD, и UPDATE, ссылающийся на
   новую колонку — компилятор падает с ошибкой 207
   «Недопустимое имя столбца», потому что на момент компиляции
   колонки ещё нет. Поэтому ALTER — в отдельном батче (с GO),
   а INSERT/UPDATE — в следующем, под транзакцией.
   ===================================================================== */

/* --- ШАГ 1: добавляем недостающие колонки в dbo.House --- */
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Lat')
BEGIN
  ALTER TABLE dbo.House ADD Lat DECIMAL(9,6)  NULL;
  PRINT N'Добавлена колонка Lat (координата широты).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Lon')
BEGIN
  ALTER TABLE dbo.House ADD Lon DECIMAL(9,6)  NULL;
  PRINT N'Добавлена колонка Lon (координата долготы).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsEmergency')
BEGIN
  ALTER TABLE dbo.House ADD IsEmergency BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsEmergency (дом признан аварийным).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsDemolished')
BEGIN
  ALTER TABLE dbo.House ADD IsDemolished BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsDemolished (дом снесён (убран из эксплуатации)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'DemolitionDate')
BEGIN
  ALTER TABLE dbo.House ADD DemolitionDate DATE          NULL;
  PRINT N'Добавлена колонка DemolitionDate (планируемая/фактическая дата сноса).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'ActNumber')
BEGIN
  ALTER TABLE dbo.House ADD ActNumber NVARCHAR(500) NULL;
  PRINT N'Добавлена колонка ActNumber (номер и дата распоряжения о признании аварийным).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'RelocationProgram')
BEGIN
  ALTER TABLE dbo.House ADD RelocationProgram NVARCHAR(200) NULL;
  PRINT N'Добавлена колонка RelocationProgram (программа переселения (РАП 2019-2025, МП, ДРЗТ...)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsResettled')
BEGIN
  ALTER TABLE dbo.House ADD IsResettled BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsResettled (дом расселён).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Quarter')
BEGIN
  ALTER TABLE dbo.House ADD Quarter NVARCHAR(50)  NULL;
  PRINT N'Добавлена колонка Quarter (квартал/микрорайон).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'ResidentsCount')
BEGIN
  ALTER TABLE dbo.House ADD ResidentsCount INT           NULL;
  PRINT N'Добавлена колонка ResidentsCount (количество жильцов).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Area')
BEGIN
  ALTER TABLE dbo.House ADD Area DECIMAL(10,2) NULL;
  PRINT N'Добавлена колонка Area (общая площадь дома, кв. м).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'HouseType')
BEGIN
  ALTER TABLE dbo.House ADD HouseType NVARCHAR(50)  NULL;
  PRINT N'Добавлена колонка HouseType (тип: Каменный/Деревянный/блокировка).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'HeatingType')
BEGIN
  ALTER TABLE dbo.House ADD HeatingType NVARCHAR(100) NULL;
  PRINT N'Добавлена колонка HeatingType (тип отопления: Теплоэнергия/АГВ/Крышная/Печное/...).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'StatusText')
BEGIN
  ALTER TABLE dbo.House ADD StatusText NVARCHAR(500) NULL;
  PRINT N'Добавлена колонка StatusText (статус дома строкой (Действующий/Аварийный/...)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'Note')
BEGIN
  ALTER TABLE dbo.House ADD Note NVARCHAR(500) NULL;
  PRINT N'Добавлена колонка Note (примечание (снесён, культурное наследие, ...)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsAuction')
BEGIN
  ALTER TABLE dbo.House ADD IsAuction BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsAuction (дом выставлен на аукцион по выбору УК).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsNoUk')
BEGIN
  ALTER TABLE dbo.House ADD IsNoUk BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsNoUk (дом без управляющей компании).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsUndefined')
BEGIN
  ALTER TABLE dbo.House ADD IsUndefined BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsUndefined (способ управления не определён).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsEgrnQuery')
BEGIN
  ALTER TABLE dbo.House ADD IsEgrnQuery BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsEgrnQuery (по дому отправлен запрос ЕГРН).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'CoordsApprox')
BEGIN
  ALTER TABLE dbo.House ADD CoordsApprox BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка CoordsApprox (координаты приблизительные (центр улицы)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'UKName')
BEGIN
  ALTER TABLE dbo.House ADD UKName NVARCHAR(200) NULL;
  PRINT N'Добавлена колонка UKName (название УК (для привязки по имени)).';
END
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'IsHiddenFromMap')
BEGIN
  ALTER TABLE dbo.House ADD IsHiddenFromMap BIT           NOT NULL DEFAULT 0;
  PRINT N'Добавлена колонка IsHiddenFromMap (дом скрыт с карты (но остаётся в базе)).';
END

/* --- ШАГ 1б: создаём dbo.UK если её нет, добавляем HousesCount --- */
IF OBJECT_ID(N'dbo.UK') IS NULL
BEGIN
  CREATE TABLE dbo.UK (
    UKID INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(200) NOT NULL UNIQUE,
    HousesCount INT NULL,
    Note NVARCHAR(500) NULL
  );
  PRINT N'Создана таблица dbo.UK';
END
ELSE
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.UK') AND name = N'HousesCount')
  BEGIN
    ALTER TABLE dbo.UK ADD HousesCount INT NULL;
    PRINT N'Добавлена колонка HousesCount в dbo.UK.';
  END
END
GO

/* =====================================================================
   ЧАСТЬ B: загрузка данных (под транзакцией).
   К этому моменту все колонки уже добавлены частью A.
   ===================================================================== */
SET XACT_ABORT ON;
BEGIN TRY
  BEGIN TRANSACTION;

  /* --- ШАГ 2: синхронизация справочника УК (dbo.UK) --- */
  -- таблица dbo.UK уже создана в части A; здесь только добавляем недостающие УК

  -- добавляем недостающие УК
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'ООО Доминион УК Гарант плюс')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'ООО Доминион УК Гарант плюс', 1);
    PRINT N'Добавлена УК: ООО Доминион УК Гарант плюс';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'ООО Доминион УК Гарант плюс';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'ООО УК "ЖЭУ Центральное"')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'ООО УК "ЖЭУ Центральное"', 1);
    PRINT N'Добавлена УК: ООО УК "ЖЭУ Центральное"';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'ООО УК "ЖЭУ Центральное"';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «ДСК»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «ДСК»', 3);
    PRINT N'Добавлена УК: УК «ДСК»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 3 WHERE Name = N'УК «ДСК»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Единство»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Единство»', 3);
    PRINT N'Добавлена УК: УК «Единство»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 3 WHERE Name = N'УК «Единство»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Жилищный Стандарт»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Жилищный Стандарт»', 22);
    PRINT N'Добавлена УК: УК «Жилищный Стандарт»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 22 WHERE Name = N'УК «Жилищный Стандарт»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Капитал»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Капитал»', 21);
    PRINT N'Добавлена УК: УК «Капитал»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 21 WHERE Name = N'УК «Капитал»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Риа Комфорт»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Риа Комфорт»', 15);
    PRINT N'Добавлена УК: УК «Риа Комфорт»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 15 WHERE Name = N'УК «Риа Комфорт»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Согласие»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Согласие»', 1);
    PRINT N'Добавлена УК: УК «Согласие»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК «Согласие»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Солидарность»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Солидарность»', 1);
    PRINT N'Добавлена УК: УК «Солидарность»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК «Солидарность»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Сфера комфорта»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Сфера комфорта»', 1);
    PRINT N'Добавлена УК: УК «Сфера комфорта»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК «Сфера комфорта»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Утум»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Утум»', 5);
    PRINT N'Добавлена УК: УК «Утум»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 5 WHERE Name = N'УК «Утум»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Эдельвейс»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Эдельвейс»', 3);
    PRINT N'Добавлена УК: УК «Эдельвейс»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 3 WHERE Name = N'УК «Эдельвейс»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК «Якутпромсервис»')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК «Якутпромсервис»', 6);
    PRINT N'Добавлена УК: УК «Якутпромсервис»';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 6 WHERE Name = N'УК «Якутпромсервис»';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Альтаир')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Альтаир', 1);
    PRINT N'Добавлена УК: УК Альтаир';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК Альтаир';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Арт Плюс')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Арт Плюс', 7);
    PRINT N'Добавлена УК: УК Арт Плюс';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 7 WHERE Name = N'УК Арт Плюс';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Веста')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Веста', 1);
    PRINT N'Добавлена УК: УК Веста';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК Веста';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Восхождение')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Восхождение', 3);
    PRINT N'Добавлена УК: УК Восхождение';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 3 WHERE Name = N'УК Восхождение';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Гарант плюс')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Гарант плюс', 1);
    PRINT N'Добавлена УК: УК Гарант плюс';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК Гарант плюс';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК ЖКХ Губинский')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК ЖКХ Губинский', 5);
    PRINT N'Добавлена УК: УК ЖКХ Губинский';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 5 WHERE Name = N'УК ЖКХ Губинский';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК ИР-Строй')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК ИР-Строй', 8);
    PRINT N'Добавлена УК: УК ИР-Строй';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 8 WHERE Name = N'УК ИР-Строй';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Кристалл')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Кристалл', 11);
    PRINT N'Добавлена УК: УК Кристалл';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 11 WHERE Name = N'УК Кристалл';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Перспектива')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Перспектива', 22);
    PRINT N'Добавлена УК: УК Перспектива';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 22 WHERE Name = N'УК Перспектива';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Прометей+')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Прометей+', 22);
    PRINT N'Добавлена УК: УК Прометей+';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 22 WHERE Name = N'УК Прометей+';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК РИФ')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК РИФ', 2);
    PRINT N'Добавлена УК: УК РИФ';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 2 WHERE Name = N'УК РИФ';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Ригель')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Ригель', 6);
    PRINT N'Добавлена УК: УК Ригель';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 6 WHERE Name = N'УК Ригель';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Роскатех')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Роскатех', 1);
    PRINT N'Добавлена УК: УК Роскатех';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК Роскатех';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК ЦАДС')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК ЦАДС', 1);
    PRINT N'Добавлена УК: УК ЦАДС';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 1 WHERE Name = N'УК ЦАДС';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Юнион')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Юнион', 57);
    PRINT N'Добавлена УК: УК Юнион';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 57 WHERE Name = N'УК Юнион';
  END
  IF NOT EXISTS (SELECT 1 FROM dbo.UK WHERE Name = N'УК Якуттеплосервис')
  BEGIN
    INSERT INTO dbo.UK (Name, HousesCount) VALUES (N'УК Якуттеплосервис', 4);
    PRINT N'Добавлена УК: УК Якуттеплосервис';
  END
  ELSE
  BEGIN
    UPDATE dbo.UK SET HousesCount = 4 WHERE Name = N'УК Якуттеплосервис';
  END

  DECLARE @uk_lookup TABLE (Name NVARCHAR(200), UKID INT);
  INSERT INTO @uk_lookup SELECT Name, UKID FROM dbo.UK;

  /* --- ШАГ 3: загрузка домов через временную таблицу #Staging --- */
  DECLARE @updated INT = 0, @inserted INT = 0;
  /* --- ШАГ 3: загрузка домов через временную таблицу #Staging --- */
  IF OBJECT_ID(N'tempdb..#Staging') IS NOT NULL DROP TABLE #Staging;
  CREATE TABLE #Staging (
    Street          NVARCHAR(100) NULL,
    HouseNo         NVARCHAR(50)  NULL,
    FullAddress     NVARCHAR(500) NULL,
    Lat             DECIMAL(9,6)  NULL,
    Lon             DECIMAL(9,6)  NULL,
    IsEmergency     BIT           NOT NULL DEFAULT 0,
    IsDemolished    BIT           NOT NULL DEFAULT 0,
    DemolitionDate  DATE          NULL,
    ActNumber       NVARCHAR(500) NULL,
    RelocationProgram NVARCHAR(200) NULL,
    IsResettled     BIT           NOT NULL DEFAULT 0,
    Quarter         NVARCHAR(50)  NULL,
    FlatsCount      INT           NULL,
    ResidentsCount  INT           NULL,
    Area            DECIMAL(10,2) NULL,
    HouseType       NVARCHAR(50)  NULL,
    HeatingType     NVARCHAR(100) NULL,
    StatusText      NVARCHAR(500) NULL,
    Note            NVARCHAR(500) NULL,
    IsAuction       BIT           NOT NULL DEFAULT 0,
    IsNoUk          BIT           NOT NULL DEFAULT 0,
    IsUndefined     BIT           NOT NULL DEFAULT 0,
    IsEgrnQuery     BIT           NOT NULL DEFAULT 0,
    CoordsApprox    BIT           NOT NULL DEFAULT 0,
    UKName          NVARCHAR(200) NULL
    -- PRIMARY KEY не ставим: в реестре есть дубликаты адресов
    -- (один и тот же дом может быть записан у разных УК).
    -- Вместо этого берём одну запись на адрес через ROW_NUMBER().
  );
  PRINT N'Создана временная таблица #Staging.';

  PRINT N'Всего домов в реестре: 463; с координатами: 406; без координат: 57 (пропущены).';
  PRINT N'--- Список домов без координат (нужно дополнить позже через SSMS) ---';
  PRINT N'  без координат: уткина д. 14 стр. 1';
  PRINT N'  без координат: уткина д. 10/1 стр. 1';
  PRINT N'  без координат: пр. М. Николаева д. 13 А';
  PRINT N'  без координат: Крупская 14';
  PRINT N'  без координат: Чернышевского 100 (88/8)';
  PRINT N'  без координат: Тимирязева, д. 53 (ТСЖ)';
  PRINT N'  без координат: пр Михаила Николаева 2/3 стр 1';
  PRINT N'  без координат: АВТОДОРОЖНАЯ, д. 19 Г';
  PRINT N'  без координат: МАТРОСОВА, д.1 строение 1';
  PRINT N'  без координат: ПОКРОВСКИЙ ТРАКТ 7 км. д. 16/4';
  PRINT N'  без координат: ПОКРОВСКИЙ ТРАКТ 7 км д. 14/2';
  PRINT N'  без координат: Покроский тракт 7 км 14';
  PRINT N'  без координат: пр. М. Николаева д. 4 к. 2Б';
  PRINT N'  без координат: КРУПСКОЙ д. 47 (49)';
  PRINT N'  без координат: ДТС-1, д. 6';
  PRINT N'  без координат: пер. Зои Космодемьянской 2 корп. 2';
  PRINT N'  без координат: пер. Зои Космодемьянской 4';
  PRINT N'  без координат: пер. Зои Космодемьянской 4 корп. 1';
  PRINT N'  без координат: Зои Космодемьянской 4/3';
  PRINT N'  без координат: ДТС-1, д. 4';
  PRINT N'  без координат: Пр. М. Николаева 36/1 А';
  PRINT N'  без координат: Покровкий тракт 7 км 16/4';
  PRINT N'  без координат: пер. Зои Космодемьянской, 2/1';
  PRINT N'  без координат: пер. Зои Космодемьянской, 2/2';
  PRINT N'  без координат: пер. Зои Космодемьянской, 4/3';
  PRINT N'  без координат: Покровский тр., 4 км., д. 2';
  PRINT N'  без координат: Покровский тр., 5 км., д. 3/2';
  PRINT N'  без координат: Покровский тракт, 10 км., д.3 (кад. номер: 14:36:000000:1958';
  PRINT N'  без координат: Покровское шоссе, 10 км., Речевая школа, д. 39/3';
  PRINT N'  без координат: Сергеляхское шоссе, 8 км., ДТС-1, д. 2';
  PRINT N'  без координат: мкр. Птицефабрика, 1';
  PRINT N'  без координат: мкр. Птицефабрика, 2';
  PRINT N'  без координат: мкр. Птицефабрика, 3';
  PRINT N'  без координат: мкр. Птицефабрика, 4';
  PRINT N'  без координат: мкр. Птицефабрика, 4/1';
  PRINT N'  без координат: мкр. Птицефабрика, 5а';
  PRINT N'  без координат: с. Капитоновка, ул. Семенова, д. 8';
  PRINT N'  без координат: мкр. Птицефабрика, 5б';
  PRINT N'  без координат: Воинская д. 2/2 2 корп.2';
  PRINT N'  без координат: Воинская д. 4/1 4 корп.1';
  PRINT N'  без координат: Воинская д. 6 6';
  PRINT N'  без координат: Воинская д. 6/1 6 корп.1';
  PRINT N'  без координат: Воинская д. 8 8';
  PRINT N'  без координат: Воинская д. 8/1 8 корп.1';
  PRINT N'  без координат: Воинская д. 9/1 9 корп.1';
  PRINT N'  без координат: ДТС - 1, (Сергеляхское шоссе 8км) 1';
  PRINT N'  без координат: ДТС-1, д. 3 (Сергеляхское шоссе
8 километр, 3) 3';
  PRINT N'  без координат: ДТС-1, д. 6 (Улица Валерия
Керемясова, 51) 51';
  PRINT N'  без координат: пер. Зои Космоденьянской 2 корп. 1';
  PRINT N'  без координат: пер. Зои Космоденьянской 2 корп. 2';
  PRINT N'  без координат: пер. Зои Космоденьянской 4';
  PRINT N'  без координат: пер. Зои Космоденьянской 4 корп. 1';
  PRINT N'  без координат: Тимирязева 43/1 43/1';
  PRINT N'  без координат: Студенческая 2 а';
  PRINT N'  без координат: Птицефабрика 12/2';
  PRINT N'  без координат: Олега Кошевого';
  PRINT N'  без координат: пер. Зои Космоденьянской';

  -- Заливаем все дома с координатами во временную таблицу (пачками по 50)
  SET NOCOUNT ON;
  -- Пакет 1 — 50
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'АВТОДОРОЖНАЯ', N'40/5', N'АВТОДОРОЖНАЯ д. 40/5', 61.983218, 129.658035, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/6', N'АВТОДОРОЖНАЯ д. 40/6', 61.98312, 129.659532, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/7', N'АВТОДОРОЖНАЯ д. 40/7', 61.982608, 129.659595, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/8', N'АВТОДОРОЖНАЯ д. 40/8', 61.98326, 129.662364, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/9', N'АВТОДОРОЖНАЯ д. 40/9', 61.983601, 129.65958, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/10', N'АВТОДОРОЖНАЯ д. 40/10', 61.983618, 129.661869, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/11', N'АВТОДОРОЖНАЯ д. 40/11', 61.983198, 129.663409, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/12', N'АВТОДОРОЖНАЯ д. 40/12', 61.983068, 129.664442, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'40/13', N'АВТОДОРОЖНАЯ д. 40/13', 61.982619, 129.665006, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'42/1', N'АВТОДОРОЖНАЯ д. 42/1', 61.999864, 129.686704, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'42/2', N'АВТОДОРОЖНАЯ д. 42/2', 61.98123, 129.665116, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'44', N'АВТОДОРОЖНАЯ д. 44', 61.999912, 129.68622, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'АВТОДОРОЖНАЯ', N'44/1', N'АВТОДОРОЖНАЯ д. 44/1', 61.982267, 129.659132, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ул. Крупской', N'37Б', N'ул. Крупской, д. 37Б', 62.019002, 129.712321, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'КРУПСКОЙ', N'37А', N'КРУПСКОЙ, д. 37А', 62.019002, 129.712321, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'КРУПСКОЙ', N'37', N'КРУПСКОЙ, д. 37', 62.019002, 129.712321, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'ЧКАЛОВА', N'2', N'ЧКАЛОВА, д. 2', 62.019415, 129.715567, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'ЧЕПАЛОВА', N'46', N'ЧЕПАЛОВА, д. 46', 62.019062, 129.714415, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'ЧЕПАЛОВА', N'39', N'ЧЕПАЛОВА, д. 39', 62.0185, 129.713618, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'ТИМИРЯЗЕВА', N'1', N'ТИМИРЯЗЕВА, д.1', 62.018198, 129.712153, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'Тимирязева', N'3', N'Тимирязева, д. 3', 62.017596, 129.712239, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ИР-Строй'),
    (N'Крупской', N'23', N'Крупской д. 23', 62.020069, 129.716533, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (холбос)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'крупской', N'21', N'крупской д. 21', 62.019919, 129.71773, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (холбос)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'чкалова', N'1', N'чкалова д. 1', 62.019627, 129.716686, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (холбос)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'чкалова', N'36', N'чкалова д. 36', 62.013673, 129.7174, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (холбос)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'уткина', N'14', N'уткина д. 14', 62.005358, 129.701596, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'уткина', N'10/1', N'уткина д. 10/1', 62.004319, 129.701944, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'уткина', N'16/1', N'уткина д. 16/1', 62.004483, 129.703664, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1Г', N'пр. М. Николаева д. 13/1Г', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1Б', N'пр. М. Николаева д. 13/1Б', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1В', N'пр. М. Николаева д. 13/1В', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1Е', N'пр. М. Николаева д. 13/1Е', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1Д', N'пр. М. Николаева д. 13/1Д', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1', N'пр. М. Николаева д. 13/1', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13/1 к.', N'пр. М. Николаева д. 13/1 к. 3', 62.003085, 129.696522, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Прометей+'),
    (N'пр. М. Николаева', N'5/1 стр1', N'пр. М. Николаева д. 5/1 стр1', 62.00433, 129.693336, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Прометей+'),
    (N'пр. М. Николаева', N'5/1 стр2', N'пр. М. Николаева д. 5/1 стр2', 62.00433, 129.693336, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Прометей+'),
    (N'пр. М. Николаева', N'5/1 стр3', N'пр. М. Николаева д. 5/1 стр3', 62.00433, 129.693336, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13 к1', N'пр. М. Николаева д. 13 к1', 62.003142, 129.693339, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Прометей+'),
    (N'пр. М. Николаева', N'13 к2', N'пр. М. Николаева д. 13 к2', 62.00433, 129.693336, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Прометей+'),
    (N'АВТОДОРОЖНАЯ', N'40', N'АВТОДОРОЖНАЯ д. 40', 61.982045, 129.661924, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'АВТОДОРОЖНАЯ', N'40/2', N'АВТОДОРОЖНАЯ д. 40/2', 61.982365, 129.664145, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'АВТОДОРОЖНАЯ', N'40/1', N'АВТОДОРОЖНАЯ д. 40/1', 61.982797, 129.663104, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'АВТОДОРОЖНАЯ', N'18', N'АВТОДОРОЖНАЯ д.18', 62.001122, 129.688606, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'ВОИНСКАЯ', N'9/2', N'ВОИНСКАЯ 9/2', 61.982895, 129.649341, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'ВОИНСКАЯ', N'9/2 корпус', N'ВОИНСКАЯ 9/2 корпус 1', 61.982895, 129.649341, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК «Капитал»'),
    (N'ВОИНСКАЯ', N'9/3', N'ВОИНСКАЯ 9/3', 61.983573, 129.650909, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'ПЕР. ГЕРМАНА ТИТОВА', N'2/5', N'ПЕР. ГЕРМАНА ТИТОВА 2/5', 61.982368, 129.653547, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/1а', N'МИКРОРАЙОН ИЛЬИНКА д. 1/1а', 61.980884, 129.651687, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/1', N'МИКРОРАЙОН ИЛЬИНКА д. 1/1', 61.980884, 129.651687, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»');

  -- Пакет 51 — 100
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/2', N'МИКРОРАЙОН ИЛЬИНКА д. 1/2', 61.980936, 129.652039, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/3', N'МИКРОРАЙОН ИЛЬИНКА д. 1/3', 61.981114, 129.652278, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/4', N'МИКРОРАЙОН ИЛЬИНКА д. 1/4', 61.981329, 129.652028, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'1/5', N'МИКРОРАЙОН ИЛЬИНКА д.1/5', 61.981527, 129.651776, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'2/7', N'МИКРОРАЙОН ИЛЬИНКА д. 2/7', 61.981512, 129.650236, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'3/1', N'МИКРОРАЙОН ИЛЬИНКА д.3/1', 61.98129, 129.649222, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'3/2', N'МИКРОРАЙОН ИЛЬИНКА д. 3/2', 61.981488, 129.648857, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'3/3', N'МИКРОРАЙОН ИЛЬИНКА д. 3/3', 61.98173, 129.648862, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'3/4', N'МИКРОРАЙОН ИЛЬИНКА д. 3/4', 61.98197, 129.648868, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'4', N'МИКРОРАЙОН ИЛЬИНКА д. 4', 61.981224, 129.650941, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'5', N'МИКРОРАЙОН ИЛЬИНКА д. 5', 61.981558, 129.651756, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Капитал»'),
    (N'АВТОДОРОЖНАЯ', N'11/1', N'АВТОДОРОЖНАЯ д. 11/1', 62.004626, 129.693455, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная энергия 2002', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Автодорожная', N'2/2', N'Автодорожная 2/2', 62.006189, 129.690849, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Ведомственная Сахаэлектрогаз', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Автодорожная', N'3/1', N'Автодорожная 3/1', 62.001148, 129.68948, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Автодорожная', N'26/1', N'Автодорожная 26/1', 61.984392, 129.675821, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Автодорожная', N'26/2', N'Автодорожная 26/2', 61.984392, 129.675821, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Автодорожная', N'36/2', N'Автодорожная 36/2', 61.989465, 129.678521, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'2', N'дежнева 2', 62.017093, 129.724967, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2778р от 19.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'4', N'дежнева 4', 62.016965, 129.724228, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2778р от 19.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'6', N'дежнева 6', 62.016913, 129.723386, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'75/1', N'дежнева 75/1', 62.013526, 129.703689, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 428р от 22.03.2024)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'77', N'дежнева 77', 62.013544, 129.700293, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1670р от 21.09.2023)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'79/1', N'дежнева 79/1', 62.012889, 129.699902, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2066р от 26.12.2019)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81', N'дежнева 81', 62.013191, 129.698414, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1443р от 22.07.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/1', N'дежнева 81/1', 62.012731, 129.698818, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/2', N'дежнева 81/2', 62.012307, 129.698848, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2578р от 28.12.2018)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/3', N'дежнева 81/3', 62.011832, 129.698745, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/4', N'дежнева 81/4', 62.011396, 129.698784, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2632р от 06.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/5', N'дежнева 81/5', 62.011207, 129.698034, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 544р от 05.04.2024)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'81/6', N'дежнева 81/6', 62.011205, 129.69701, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'83', N'дежнева 83', 62.012986, 129.697575, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1092р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'83/1', N'дежнева 83/1', 62.012377, 129.69823, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2780р от 19.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'85', N'дежнева 85', 62.012722, 129.696935, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2665р от 13.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'85/1', N'дежнева 85/1', 62.012474, 129.697449, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1092р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'85/2', N'дежнева 85/2', 62.012189, 129.697381, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1062р от 06.06.2025)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'87', N'дежнева 87', 62.012273, 129.696274, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'87/1', N'дежнева 87/1', 62.011705, 129.697045, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 448р от 05.03.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'89/2', N'дежнева 89/2', 62.011729, 129.696262, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1062р от 06.06.2025)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'дежнева', N'91', N'дежнева 91', 62.011317, 129.695881, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Красильникова', N'3/1', N'Красильникова 3/1', 62.006943, 129.68452, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.12.2020 г. №2042р', N'расселял Утум-Строй+', 1, N'10.65', 8, 24, 455, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Красильникова', N'11/1', N'Красильникова 11/1', 62.004552, 129.683815, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.12.2022 г. № 2665р', NULL, 0, N'10.65', 4, 8, 136, N'блокировка', N'Теплоэнергия', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Красильникова', N'11/2', N'Красильникова 11/2', 62.004645, 129.683167, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 26.07.2021 г. № 1463р', NULL, 0, N'10.65', 4, 14, 163.9, N'блокировка', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1463р от 26.07.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Красильникова', N'11/3', N'Красильникова 11/3', 62.004467, 129.684336, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Лизы Чайкиной', N'2', N'Лизы Чайкиной 2', 62.007258, 129.713963, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 03.03.2020 №284р.', NULL, 0, N'122', 16, 33, 526.9, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 284р от 03.03.2020)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Ленина', N'63', N'Ленина 63', 61.903385, 129.634852, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 19.12.2022 г. № 2780р', NULL, 0, N'117', 14, 37, 567.70, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2780р от 19.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Матросова', N'1/1', N'Матросова 1/1', 62.009158, 129.71876, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.12.2022 г. № 2621р', NULL, 0, N'122', 12, 36, 573, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2621р от 05.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Матросова', N'1/2', N'Матросова 1/2', 62.008944, 129.714668, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.12.2022 г. № 2621р', NULL, 0, N'122', 12, 30, 573, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2621р от 05.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Матросова', N'1/3', N'Матросова 1/3', 62.008387, 129.714697, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.12.2022 г. № 2621р', NULL, 0, N'122', 12, 36, 573, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2621р от 05.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'31', N'Тимирязева 31', 62.012361, 129.712969, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 19.12.2022 г. № 2782р', NULL, 0, N'121', 16, 39, 501.4, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2782р от 19.12.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'43', N'Тимирязева 43', 62.008422, 129.713084, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'122', 16, 45, 521.3, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион');

  -- Пакет 101 — 150
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Тимирязева', N'49', N'Тимирязева 49', 62.005867, 129.713268, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.06.2018 г. №1359р.', NULL, 0, N'123', 9, 19, 244.8, N'блокировка', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1359р от 28.06.2018)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'64', N'Тимирязева 64', 62.006329, 129.712402, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 22.07.2021 г. №1443р', NULL, 0, N'123', 16, 45, 550.4, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1443р от 22.07.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'66', N'Тимирязева 66', 62.005903, 129.712415, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'68', N'Тимирязева 68', 62.005544, 129.712251, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 16.07.2018 г. №1543р.', NULL, 0, N'124', 17, 32, 520, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1543р от 16.07.2018)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Тимирязева', N'70', N'Тимирязева 70', 62.005031, 129.712356, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 03.03.2020 г. №286р.', NULL, 0, N'124', 16, 37, 484.9, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 286р от 03.03.2020)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'58', N'Чернышевского 58', 62.010402, 129.720369, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.08.2021 г. № 1669р', NULL, 0, N'122', 16, 37, 776.5, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1669р от 30.08.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'72', N'Чернышевского 72', 62.007044, 129.718111, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 10.02.2026 №206р', NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'99/1', N'Чернышевского 99/1', 61.995469, 129.710596, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 02.09.2022 г. №1910р', NULL, 0, N'Якутск', 6, 11, 133.3, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1910р от 02.09.2022)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'99/2', N'Чернышевского 99/2', 61.999043, 129.712358, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'114/1', N'Чернышевского 114/1', 61.997962, 129.702957, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 16.11.2018 г. №2317р', NULL, 0, N'11', 8, 17, 217.3, N'блокировка', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2317р от 16.11.2018)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'114/2', N'Чернышевского 114/2', 61.998321, 129.703096, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'11', 10, 29, 263.5, N'блокировка', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'116/1', N'Чернышевского 116/1', 62.001525, 129.710842, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'116/6', N'Чернышевского 116/6', 61.998841, 129.700268, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'116/7', N'Чернышевского 116/7', 61.998854, 129.699962, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Чернышевского', N'116/9', N'Чернышевского 116/9', 61.99855, 129.699809, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'Ярославского', N'54', N'Ярославского 54', 62.028565, 129.737576, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Юнион'),
    (N'СЕРГЕЛЯХСКОЕ ШОССЕ', N'1', N'СЕРГЕЛЯХСКОЕ ШОССЕ д. 1', 62.036584, 129.632021, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (агату)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЖКХ Губинский'),
    (N'СЕРГЕЛЯХСКОЕ ШОССЕ', N'1/1', N'СЕРГЕЛЯХСКОЕ ШОССЕ д. 1/1', 62.036584, 129.632021, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Вед. Котельная (агату)', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЖКХ Губинский'),
    (N'ЧЕРНЫШЕВСКОГО', N'118', N'ЧЕРНЫШЕВСКОГО д. 118', 61.996736, 129.697951, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЖКХ Губинский'),
    (N'ЧЕРНЫШЕВСКОГО', N'118/1', N'ЧЕРНЫШЕВСКОГО д. 118/1', 61.997569, 129.699, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЖКХ Губинский'),
    (N'ЧЕРНЫШЕВСКОГО', N'118/3', N'ЧЕРНЫШЕВСКОГО д. 118/3', 61.997699, 129.698107, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЖКХ Губинский'),
    (N'КРАСИЛЬНИКОВА', N'15', N'КРАСИЛЬНИКОВА д.15', 62.00199, 129.684403, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'воинская', N'10/1', N'воинская д. 10/1', 61.980477, 129.653163, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'строда', N'15', N'строда д. 15', 62.017754, 129.722827, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'космонавта Г. Титова', N'2/2', N'космонавта Г. Титова д. 2/2', 61.983059, 129.655889, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'космонавта Г. Титова', N'2/3', N'космонавта Г. Титова д. 2/3', 61.982847, 129.656696, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'ДЕЖНЕВА', N'75', N'ДЕЖНЕВА, д. 75', 62.014092, 129.703574, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'АВТОДОРОЖНАЯ', N'47/2', N'АВТОДОРОЖНАЯ 47/2', 61.979928, 129.667948, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'АВТОДОРОЖНАЯ', N'47/3', N'АВТОДОРОЖНАЯ 47/3', 61.979844, 129.667436, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'АВТОДОРОЖНАЯ', N'49/1', N'АВТОДОРОЖНАЯ 49/1', 61.98008, 129.66726, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'воинская', N'10/2', N'воинская д. 10/2', 61.980204, 129.652871, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'воинская', N'1', N'воинская д. 1', 61.983568, 129.654084, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'воинская', N'1А', N'воинская д. 1А', 61.983884, 129.653459, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'воинская', N'9', N'воинская д. 9', 61.98411, 129.652682, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'веры захаровой', N'8', N'веры захаровой д. 8', 61.982103, 129.648061, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'веры захаровой', N'10', N'веры захаровой д. 10', 61.982382, 129.64768, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'7', N'Птицефабрика, д. 7', 62.000269, 129.609672, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'8', N'Птицефабрика, д. 8', 61.998414, 129.616266, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'9', N'Птицефабрика, д. 9', 61.998233, 129.617145, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'12', N'Птицефабрика, д. 12', 61.997452, 129.614371, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'13', N'Птицефабрика, д. 13', 61.997505, 129.616801, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'11', N'Птицефабрика, д. 11', 61.9972, 129.618198, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'Птицефабрика', N'12/3', N'Птицефабрика, д. 12/3', 61.9984, 129.61524, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Жилищный Стандарт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'15', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.15', 61.97997, 129.649056, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'15/1', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.15/1', 61.97924, 129.649397, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'15/2', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.15/2', 61.97851, 129.649306, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'15/3', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.15/3', 61.979475, 129.648176, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'15/4', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.15/4', 61.978748, 129.648162, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'17', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.17', 61.980605, 129.648337, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ', N'17/1', N'ул. ЛЕТЧИЦЫ ВЕРЫ ЗАХАРОВОЙ, д.17/1', 61.980182, 129.64751, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»');

  -- Пакет 151 — 200
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'ул. Александра Захарченко', N'5', N'ул. Александра Захарченко 5', 61.972087, 129.647776, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Александра Захарченко', N'7', N'ул. Александра Захарченко 7', 61.971542, 129.647167, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Александра Захарченко', N'9', N'ул. Александра Захарченко 9', 61.971018, 129.646549, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Александра Захарченко', N'11', N'ул. Александра Захарченко 11', 61.970434, 129.645908, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Александра Захарченко', N'13', N'ул. Александра Захарченко 13', 61.969792, 129.645544, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Юрия шафера', N'6', N'ул. Юрия шафера д 6', 61.971665, 129.649174, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Юрия Шафера', N'4', N'ул. Юрия Шафера, д. 4', 61.971966, 129.650059, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'ул. Юрия шафера', N'8', N'ул. Юрия шафера д 8', 61.970832, 129.648839, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Риа Комфорт»'),
    (N'АВТОДОРОЖНАЯ', N'36/6', N'АВТОДОРОЖНАЯ д. 36/6', 61.988511, 129.680218, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'ПЕР. Г. ТИТОВА', N'10', N'ПЕР. Г. ТИТОВА, Д. 10', 61.979766, 129.654152, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'ИЛЬИНКА', N'2/6', N'ИЛЬИНКА Д. 2/6', 61.9817188, 129.6504307, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Кристалл'),
    (N'МИКРОРАЙОН ИЛЬИНКА', N'2', N'МИКРОРАЙОН ИЛЬИНКА д.2', 61.980784, 129.650018, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'ИЛЬИНКА', N'2/3', N'ИЛЬИНКА Д. 2/3', 61.9817188, 129.6504307, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 1, N'УК Кристалл'),
    (N'ЛЕНИНА', N'57/1', N'ЛЕНИНА 57/1', 62.016876, 129.721534, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'АВТОДОРОЖНАЯ', N'8/8', N'АВТОДОРОЖНАЯ д. 8/8', 61.993931, 129.686149, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'ПЕР. Г. ТИТОВА', N'8', N'ПЕР. Г. ТИТОВА, Д. 8 (10)', 61.979766, 129.654152, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная ГупЖКХ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'Красильникова', N'4', N'Красильникова, д. 4', 62.001649, 129.680998, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'Красильникова', N'4/1', N'Красильникова, д. 4/1', 62.002509, 129.680837, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'Тимирязева', N'60', N'Тимирязева 60', 62.009003, 129.712097, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1094р', NULL, 0, N'8', 16, 59, 898.6, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Кристалл'),
    (N'ЛЕНИНА', N'58', N'ЛЕНИНА д. 58', 61.903902, 129.633466, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Солидарность»'),
    (N'КРАСИЛЬНИКОВА', N'7', N'КРАСИЛЬНИКОВА д. 7', 62.006451, 129.683477, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Согласие»'),
    (N'пр. Михаила Николаева', N'11/4Б', N'пр. Михаила Николаева д. 11/4Б', 61.999711, 129.694263, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Якуттеплосервис'),
    (N'ЛЕНИНА', N'52', N'ЛЕНИНА дом 52', 61.904748, 129.634737, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Якуттеплосервис'),
    (N'пр. Михаила Николаева', N'10/2В', N'пр. Михаила Николаева д. 10/2В', 62.003091, 129.687835, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Якуттеплосервис'),
    (N'Чернышевского', N'50/1', N'Чернышевского 50/1', 62.016025, 129.723204, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Роскатех'),
    (N'КРУПСКОЙ', N'9А', N'КРУПСКОЙ, д. 9А, корп.1', 62.020744, 129.723746, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Восхождение'),
    (N'пр. ЛЕНИНА', N'56/1', N'пр. ЛЕНИНА д. 56/1', 61.904126, 129.633838, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Восхождение'),
    (N'пр. ЛЕНИНА', N'56', N'пр. ЛЕНИНА д. 56', 61.904386, 129.63424, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Восхождение'),
    (N'пр. Михаила Николаева', N'11/4А', N'пр. Михаила Николаева д. 11/4А', 61.999711, 129.694263, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК ЦАДС'),
    (N'СТРОДА', N'16', N'СТРОДА, д. 16', 62.018405, 129.722383, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Эдельвейс»'),
    (N'СТРОДА', N'16/1', N'СТРОДА, д. 16/1', 62.018289, 129.721699, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Эдельвейс»'),
    (N'СТРОДА', N'16/2', N'СТРОДА, д. 16/2', 62.018703, 129.722521, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Эдельвейс»'),
    (N'Чернышевского', N'110а', N'Чернышевского 110а', 61.998143, 129.703964, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК РИФ'),
    (N'Чернышевского', N'110Б', N'Чернышевского 110Б', 61.998143, 129.703964, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК РИФ'),
    (N'Матросова', N'19/2', N'Матросова 19/2', 62.009181, 129.708668, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'Лизы чайкиной', N'7', N'Лизы чайкиной 7', 62.006894, 129.714357, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'Тимирязева', N'41', N'Тимирязева 41', 62.008831, 129.713339, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'Чернышевского', N'94/1', N'Чернышевского 94/1', 62.001151, 129.711367, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'Нагорная', N'11', N'Нагорная 11', 61.997112, 129.614593, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'пр. М. Николаева', N'8/3', N'пр. М. Николаева д. 8/3', 62.004358, 129.687156, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2121р от 28.12.2020)', NULL, 0, 0, 0, 0, 0, N'УК Ригель'),
    (N'пр. Ленина', N'53', N'пр. Ленина, д. 53', 62.018451, 129.721157, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Гарант плюс'),
    (N'КРАСИЛЬНИКОВА', N'3/2', N'КРАСИЛЬНИКОВА, д. 3/2', 62.007611, 129.685113, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Альтаир'),
    (N'ЧКАЛОВА', N'11', N'ЧКАЛОВА д. 11', 62.017198, 129.716997, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Сфера комфорта»'),
    (N'КРАСНОЯРОВА', N'22', N'КРАСНОЯРОВА, д. 22', 62.014928, 129.714605, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «ДСК»'),
    (N'МАТРОСОВА', N'1', N'МАТРОСОВА, д.1', 62.009158, 129.71876, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «ДСК»'),
    (N'пр. М. Николаева', N'28/2', N'пр. М. Николаева д. 28/2', 61.992277, 129.679812, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 33р от 12.01.2024)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'28/14', N'пр. М. Николаева д. 28/14', 61.992386, 129.676641, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2475р от 16.12.2024)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'28/15', N'пр. М. Николаева д. 28/15', 61.992026, 129.676561, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'4/2', N'пр. М. Николаева д. 4/2', 62.003565, 129.687898, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Ведомственная Энергия2002', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'Чернышевского', N'58А', N'Чернышевского д. 58А', 62.010402, 129.720369, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива');

  -- Пакет 201 — 250
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Тимирязева', N'36', N'Тимирязева 36', 62.012673, 129.71199, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 10.07.2019 г. №1162р', NULL, 0, N'6', 16, 37, 499.1, N'Перспектива', N'АВАРИЙНЫЙ (№ 1162р от 10.07.2019)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'чернышевского', N'114/8', N'чернышевского д. 114/8', 61.998294, 129.70052, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'8/5', N'пр. М. Николаева д. 8/5', 62.00446, 129.688376, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 376р от 01.03.2021)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'Крупской', N'26', N'Крупской д. 26', 62.002632, 129.71151, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.09.2024г. №1768р', NULL, 0, N'124', 18, 35, 979.3, N'Каменный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1768р от 13.09.2024)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'8/7', N'пр. М. Николаева д. 8/7', 62.004281, 129.688301, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'8/1', N'пр. М. Николаева д. 8/1', 62.004231, 129.688973, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'8/2', N'пр. М. Николаева д. 8/2', 62.003987, 129.688862, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'8/6', N'пр. М. Николаева д. 8/6', 62.004678, 129.688106, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'28/9', N'пр. М. Николаева д. 28/9', 61.992537, 129.678975, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'28/10', N'пр. М. Николаева д. 28/10', 61.992146, 129.678704, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'28/13', N'пр. М. Николаева д. 28/13', 61.99225, 129.677085, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'чернышевского', N'114/9', N'чернышевского д. 114/9', 61.997819, 129.700486, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1207р от 26.07.2017)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'36/4', N'пр. М. Николаева д. 36/4', 61.988865, 129.67907, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'пр. М. Николаева', N'36/5', N'пр. М. Николаева д. 36/5', 61.989022, 129.679699, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'Красильникова', N'9/1', N'Красильникова 9/1', 62.005824, 129.682945, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.11.2020 г. №1869р', NULL, 0, N'10.65', 12, 26, 670.4, N'Перспектива', N'АВАРИЙНЫЙ (№ 1869р от 30.11.2020)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'9/2', N'Красильникова 9/2', 62.005803, 129.683568, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.11.2020 г. №1869р', NULL, 0, N'10.65', 12, 28, 622.9, N'Перспектива', N'АВАРИЙНЫЙ (№ 1869р от 30.11.2020)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'9/3', N'Красильникова 9/3', 62.006074, 129.684261, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.11.2020 г. №1869р', NULL, 0, N'10.65', 12, 23, 506.4, N'Перспектива', N'АВАРИЙНЫЙ (№ 1869р от 30.11.2020)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'9/4', N'Красильникова 9/4', 62.006578, 129.684453, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'9/5', N'Красильникова 9/5', 62.006367, 129.685087, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'113/1', N'Чернышевского д. 113/1', 61.995237, 129.694948, 1, 0, '2024-07-01', N'Распоряжение Окружной администрации города Якутска от 23.05.2016 г. №811р', N'РАП 2019-2025', 1, N'13', 27, 31, 1123, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 811р от 23.05.2016)', NULL, 0, 0, 0, 0, 0, N'УК Перспектива'),
    (N'ПТИЦЕФАБРИКА', N'16', N'ПТИЦЕФАБРИКА, д. 16', 61.997622, 129.615715, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'Неустроева', N'32', N'Неустроева, д. 32', 62.011906, 129.711399, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Крышная', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'птицефабрика', N'4', N'птицефабрика д. 4', 62.000971, 129.611222, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'Птицефабрика', N'6', N'Птицефабрика, д. 6', 62.000451, 129.610814, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'птицефабрика', N'3', N'птицефабрика д. 3', 62.001287, 129.610991, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'птицефабрика', N'1', N'птицефабрика д. 1', 62.001794, 129.610621, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'птицефабрика', N'2', N'птицефабрика д. 2', 62.001528, 129.610815, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Деревянный', N'Теплоэнергия', N'АВАРИЙНЫЙ (№ 1833р от 29.08.2018)', NULL, 0, 0, 0, 0, 0, N'УК Арт Плюс'),
    (N'ЧЕПАЛОВА', N'37', N'ЧЕПАЛОВА д. 37', 62.018465, 129.714632, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'ООО Доминион УК Гарант плюс'),
    (N'ТИМИРЯЗЕВА', N'15', N'ТИМИРЯЗЕВА д. 15', 62.01627, 129.712419, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'Дежнева', N'30', N'Дежнева, д. 30', 62.015979, 129.712987, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'Красноярова', N'15', N'Красноярова, д. 15', 62.014555, 129.716871, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'красильникова', N'7/1', N'красильникова д. 7/1', 62.005775, 129.686036, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'красильникова', N'7/2', N'красильникова д. 7/2', 62.006389, 129.685947, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'пр. М. Николаева', N'8/9', N'пр. М. Николаева д. 8/9', 62.005715, 129.687186, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Якутпромсервис»'),
    (N'АВТОДОРОЖНАЯ', N'2/4', N'АВТОДОРОЖНАЯ д. 2/4', 62.005865, 129.688266, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Утум»'),
    (N'ЯРОСЛАВСКОГО', N'48', N'ЯРОСЛАВСКОГО, д. 48 ст. 1', 62.017875, 129.724533, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Утум»'),
    (N'Байкалова', N'2', N'Байкалова, д. 2', 62.013858, 129.718894, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Утум»'),
    (N'пр. М. Николаева', N'2 к.3', N'пр. М. Николаева д. 2 к.3', 62.006391, 129.692214, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'АГВ', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Утум»'),
    (N'ЧЕПАЛОВА', N'2', N'ЧЕПАЛОВА д. 2', 62.019336, 129.727877, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'АВАРИЙНЫЙ (№ 488р от 21.03.2022)', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЧЕПАЛОВА', N'4', N'ЧЕПАЛОВА д. 4', 62.020083, 129.72898, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЧЕПАЛОВА', N'5', N'ЧЕПАЛОВА д. 5', 62.019696, 129.726432, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'АВАРИЙНЫЙ (№ 488р от 21.03.2022)', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЧКАЛОВА', N'56', N'ЧКАЛОВА д. 56', 62.010932, 129.718188, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'АВАРИЙНЫЙ (№ 2621р от 05.12.2022)', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЯРОСЛАВСКОГО', N'40/2', N'ЯРОСЛАВСКОГО д. 40/2', 62.108533, 129.770882, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЯРОСЛАВСКОГО', N'40/3', N'ЯРОСЛАВСКОГО д. 40/3', 62.028565, 129.737576, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ЯРОСЛАВСКОГО', N'53', N'ЯРОСЛАВСКОГО д. 53', 62.019027, 129.725733, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокированная', N'Печное', N'Действующий', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ленина', N'62', N'Ленина д. 62', 62.016038, 129.719924, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Единство»'),
    (N'Ленина', N'62/1', N'Ленина д. 62/1', 62.016076, 129.719431, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Единство»'),
    (N'Красноярова', N'1', N'Красноярова д. 1', 62.014873, 129.719912, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Каменный', N'Теплоэнергия', N'Действующий', NULL, 0, 0, 0, 0, 0, N'УК «Единство»'),
    (N'Байкалова', N'14 корп.', N'Байкалова 14 корп. 1', 62.0132442, 129.7143079, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Воинская', N'2', N'Воинская д. 2', 62.125515, 129.745351, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 0, 0, NULL);

  -- Пакет 251 — 300
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Воинская', N'2/2', N'Воинская д. 2/2', 61.985275, 129.652007, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Не определен', NULL, 0, 0, 1, 1, 0, NULL),
    (N'Воинская', N'4', N'Воинская д. 4', 61.984738, 129.651898, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 1, 0, NULL),
    (N'Воинская', N'4/1', N'Воинская д. 4/1', 61.985137, 129.651431, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Не определен', NULL, 0, 0, 1, 1, 0, NULL),
    (N'Воинская', N'6', N'Воинская д. 6', 61.984209, 129.651771, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.11.2025 г. №2139р', NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 2139р от 07.11.2025)', N'АВАРИЙНЫЙ', NULL, 0, 0, 1, 1, 0, NULL),
    (N'Воинская', N'6/1', N'Воинская д. 6/1', 61.980752, 129.654228, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 1, 0, NULL),
    (N'Воинская', N'8', N'Воинская д. 8', 61.984463, 129.650621, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.05.2020 г. №673р', NULL, 0, N'ДСК', 4, 6, 159.7, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 673р от 13.05.2020)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 1, 0, NULL),
    (N'Воинская', N'8/1', N'Воинская д. 8/1', 61.984865, 129.650182, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 16.11.2021 г. № 2174р', NULL, 0, N'ДСК', 3, 11, 159.7, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 2174р от 16.11.2021)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 1, 0, NULL),
    (N'Воинская', N'9/1', N'Воинская д. 9/1', 61.982867, 129.650854, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Не определен', NULL, 0, 0, 1, 1, 0, NULL),
    (N'ДТС-1', N'1', N'ДТС-1, д. 1 (Сергеляхское шоссе 8км)', 62.002901, 129.628063, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'МКД (ЯТС)', N'АВАРИЙНЫЙ (№ 1543р от 16.07.2018)', N'Определен', NULL, 0, 0, 0, 0, 1, NULL),
    (N'ДТС-1', N'3', N'ДТС-1, д. 3', 62.002901, 129.628063, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 1, 1, NULL),
    (N'Лесная', N'1', N'Лесная 1', 61.995432, 129.615653, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лесная', N'2', N'Лесная 2', 61.995677, 129.615836, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лесная', N'3', N'Лесная 3', 62.109735, 129.743857, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 11.12.2017 г. №2083р', NULL, 0, N'Автодорожный', 3, 9, 104.4, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 2083р от 11.12.2017)', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лесная', N'4', N'Лесная 4', 61.995785, 129.615312, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 06.06.2022 г. №1172р', NULL, 0, N'Автодорожный', 2, 12, 111, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1172р от 06.06.2022)', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лесная', N'5', N'Лесная 5', 61.995632, 129.614529, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лизы Чайкиной', N'1', N'Лизы Чайкиной 1', 62.007023, 129.716757, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 14.08.2017 №1342р.', NULL, 0, N'123', 8, 23, 291.9, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1342р от 14.08.2017)', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Лизы Чайкиной', N'3', N'Лизы Чайкиной 3', 62.00699, 129.715914, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 20.11.2017 г. №1947р', NULL, 0, N'123', 15, 30, 260.5, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1947р от 20.11.2017)', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Олега Кошевого', N'3', N'Олега Кошевого 3', 62.007937, 129.711944, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', NULL, NULL, 0, 1, 0, 0, 0, NULL),
    (N'пр. Ленина', N'63/2', N'пр. Ленина 63/2', 62.014126, 129.720226, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'остаются  в ЯТС', NULL, 0, 1, 0, 0, 0, NULL),
    (N'пр. Ленина', N'63/3', N'пр. Ленина 63/3', 62.013884, 129.720268, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1669р от 30.08.2021)', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'пр. Михаила Николаева', N'8/1', N'пр. Михаила Николаева 8/1', 62.004231, 129.688973, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'5', N'Птицефабрика 5', 61.995362, 129.617792, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'5A', N'Птицефабрика 5A', 62.000905, 129.613953, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'5Б', N'Птицефабрика 5Б', 62.001724, 129.61159, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'1А', N'Птицефабрика 1А', 62.001794, 129.610621, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Не определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'4 корп.', N'Птицефабрика 4 корп. 1', 62.000971, 129.611222, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1406р от 16.07.2021)', N'Определен', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Птицефабрика', N'12 корп.2', N'Птицефабрика 12 корп.2', 61.997452, 129.614371, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 645п от 26.08.2024)', N'Не определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'6', N'Студенческая 6', 61.995951, 129.616864, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 24.11.2023 г. № 2178р', NULL, 0, N'Автодорожный', 3, 12, 162.9, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 2178р от 24.11.2023)', N'Определен', N'О внес изм в распоряжение Окружной администрации города Якутска от 09.01.2024 г. № 3р', 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'7', N'Студенческая 7', 61.995044, 129.617597, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1094р', NULL, 0, N'Автодорожный', 5, 17, 180.6, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Студенческая', N'8', N'Студенческая 8', 61.99558, 129.616739, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Студенческая', N'9', N'Студенческая 9', 61.994594, 129.617052, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1094р', NULL, 0, N'Автодорожный', 10, 46, 165.1, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'10', N'Студенческая 10', 61.995278, 129.616267, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 15.01.2026 г. № 17р', NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 17р от 15.01.2026)', N'Определен', NULL, 1, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'12', N'Студенческая 12', 61.983584, 129.618188, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1094р', NULL, 0, N'Автодорожный', 4, 15, 161.1, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'14', N'Студенческая 14', 61.994368, 129.615562, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 10.06.2021 г. №1138р', NULL, 0, N'Автодорожный', 4, 7, 125.9, N'блокировка (ЯТС)', N'АВАРИЙНЫЙ (№ 1138р от 10.06.2021)', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Тимирязева', N'43/1', N'Тимирязева 43/1', 62.007957, 129.713224, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (ЯТС)', N'Действующий', N'Определен', NULL, 0, 0, 0, 1, 0, NULL),
    (N'Чкалова', N'24', N'Чкалова 24', 62.016668, 129.716462, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 27.07.2020 г. №1131р', N'РАП 2020-2026', 1, N'37', 16, 32, 361, N'мкд (ЯТС)', N'АВАРИЙНЫЙ (№ 1131р от 27.07.2020)', N'Определен', NULL, 1, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'1', N'Студенческая 1', 61.995827, 129.618536, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.11.2020 г. №1869р.', NULL, 0, N'Автодорожный', 5, 12, 196.2, N'блокировка', N'АВАРИЙНЫЙ (№ 1869р от 30.11.2020)', N'Определен', N'О внес изм в распоряжение Окружной администрации города Якутска от 03.02.2026 г. № 152р', 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'3', N'Студенческая 3', 61.995609, 129.618215, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1094р', NULL, 0, N'Автодорожный', 4, 8, 187.2, N'МКД', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'2', N'Студенческая 2 а', 61.9835835, 129.6181884, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Определен', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Студенческая', N'4', N'Студенческая 4', 61.996227, 129.617377, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.10.2017 г. №1716р', NULL, 0, N'Автодорожный', 17, 35, 541.5, N'МКД', N'АВАРИЙНЫЙ (№ 1716р от 13.10.2017)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Студенческая', N'5', N'Студенческая 5', 61.995362, 129.617792, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Нагорная', N'3', N'Нагорная 3', 61.996171, 129.615663, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Определен', NULL, 1, 1, 0, 0, 0, NULL),
    (N'Нагорная', N'5', N'Нагорная 5', 61.996248, 129.615145, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.11.2025 г. № 2139р', NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'АВАРИЙНЫЙ (№ 2139р от 07.11.2025)', N'Определен', NULL, 1, 1, 0, 0, 0, NULL),
    (N'Нагорная', N'7', N'Нагорная 7', 61.996353, 129.61479, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Определен', NULL, 1, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'10', N'Птицефабрика 10', 61.998074, 129.618006, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'МКД', N'АВАРИЙНЫЙ (№ 1094р от 07.06.2021)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Пр. М. Николаева', N'24', N'Пр. М. Николаева 24', 61.996953, 129.683394, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'МКД', N'АВАРИЙНЫЙ (№ 2217р от 21.10.2022)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Байкалова', N'6', N'Байкалова 6', 62.013554, 129.716345, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 10.04.2019 №608р.', NULL, 0, N'117', 20, 31, 537.9, N'МКД', N'АВАРИЙНЫЙ (№ 608р от 10.04.2019)', N'Определен', N'О внес изменений 126р от 30.01.2026 г.', 0, 1, 0, 0, 0, NULL),
    (N'Лесная', N'6', N'Лесная 6', 62.109981, 129.744585, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Озерная', N'4', N'Озерная 4', 61.995104, 129.61473, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Нагорная', N'1', N'Нагорная 1', 61.996066, 129.6162, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка', N'Действующий', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL);

  -- Пакет 301 — 350
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Тимирязева', N'62', N'Тимирязева 62', 62.008556, 129.712424, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 27.02.2018 г. №291р.', NULL, 0, N'8', 8, 25, 188.6, N'блокировка (Юнион)', N'АВАРИЙНЫЙ (№ 291р от 27.02.2018)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Тимирязева', N'62/1', N'Тимирязева 62/1', 62.008234, 129.712208, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 27.02.2018 г. №291р.', NULL, 0, N'8', 7, 17, 195.7, N'блокировка (Юнион)', N'АВАРИЙНЫЙ (№ 291р от 27.02.2018)', N'Не определен', NULL, 0, 1, 1, 0, 0, NULL),
    (N'Пр. М. Николаева', N'38/22', N'Пр. М. Николаева 38/22', 61.989857, 129.671714, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'мкд (Юнион)', N'АВАРИЙНЫЙ (№ 226р от 16.02.2017)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Пр. М. Николаева', N'38/24', N'Пр. М. Николаева 38/24', 61.990283, 129.671679, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'мкд (Юнион)', N'АВАРИЙНЫЙ (№ 596р от 21.04.2017)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Пр. М. Николаева', N'3/4', N'Пр. М. Николаева 3/4', 62.005273, 129.694896, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'блокировка (Юнион)', N'АВАРИЙНЫЙ (№ 1959р от 13.12.2019)', N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Байкалова', N'25/2', N'Байкалова 25/2', 62.012698, 129.71281, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.09.2017 г. №1473р', NULL, 0, N'121', 16, 17, 527.2, N'мкд (Юнион)', N'АВАРИЙНЫЙ (№ 1473р от 05.09.2017)', N'Определен', N'Внесения изменения в распоряжении Окружной администрации города Якутска от 04.10.2017 г. №1668р', 0, 1, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/14', N'Михаила Николаева 28/14', 61.992386, 129.676641, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 16.12.2024 г. № 2475р', NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'АВАРИЙНЫЙ (№ 2475р от 16.12.2024)', N'АВАРИЙНЫЙ', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/15', N'Михаила Николаева 28/15', 61.992026, 129.676561, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 1, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/13', N'Михаила Николаева 28/13', 61.99225, 129.677085, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 1, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/2', N'Михаила Николаева 28/2', 61.992277, 129.679812, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 12.01.2024 г. № 33р.', NULL, 0, N'14', 29, 59, 442.5, N'Перспектива', N'АВАРИЙНЫЙ (№ 33р от 12.01.2024)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'36/5', N'Михаила Николаева 36/5', 61.989022, 129.679699, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 1, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8/2', N'Михаила Николаева 8/2', 62.003987, 129.688862, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'65', 4, 8, 136, N'Перспектива', N'АВАРИЙНЫЙ (№ 2696р от 28.12.2021)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8/5', N'Михаила Николаева 8/5', 62.00446, 129.688376, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 01.03.2021 г. № 376р.', NULL, 0, N'10.65', 5, 8, 70, N'Перспектива', N'АВАРИЙНЫЙ (№ 376р от 01.03.2021)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/1', N'Михаила Николаева 28/1', 61.991883, 129.679194, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.12.2023 г. № 2254р.', NULL, 0, N'14', 16, 46, 526.8, N'Перспектива', N'АВАРИЙНЫЙ (№ 2254р от 07.12.2023)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/10', N'Михаила Николаева 28/10', 61.992146, 129.678704, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/12', N'Михаила Николаева 28/12', 61.992118, 129.677594, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/9', N'Михаила Николаева 28/9', 61.992537, 129.678975, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'4/2', N'Михаила Николаева 4/2', 62.003565, 129.687898, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'36/4', N'Михаила Николаева 36/4', 61.988865, 129.67907, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'114/8', N'Чернышевского 114/8', 61.998294, 129.70052, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'Перспектива', N'Действующий', NULL, NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'114/9', N'Чернышевского 114/9', 61.997819, 129.700486, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 26.07.2017 г. №1207р', NULL, 0, N'11', 9, 18, 217.3, N'Перспектива', N'АВАРИЙНЫЙ (№ 1207р от 26.07.2017)', N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'1/2', N'Михаила Николаева, 1/2', 62.005804, 129.694434, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 30.08.2018 г. № 1852р.', NULL, 0, N'11', 22, 1, 444.4, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'3/1', N'Михаила Николаева, 3/1', 62.005393, 129.693612, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'11', 12, 29, 857, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'3/3', N'Михаила Николаева, 3/3', 62.005304, 129.694214, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 27.07.2020 г. № 1131р.', NULL, 0, N'11', 4, 10, 117, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'3/4', N'Михаила Николаева, 3/4', 62.005273, 129.694896, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 13.12.2019 г. № 1959р.', NULL, 0, N'11', 8, 26, 274, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'4д', N'Михаила Николаева, 4д', 62.004756, 129.691595, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 10.01.2017 г. № 14р.', NULL, 0, N'10.65', 10, 13, 300, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8/3', N'Михаила Николаева, 8/3', 62.004358, 129.687156, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 28.12.2020 г. № 2121р.', NULL, 0, N'10.65', 18, 38, 892.2, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8/4', N'Михаила Николаева, 8/4', 62.005715, 129.687186, 1, 0, '2021-11-15', N'Распоряжение Окружной администрации города Якутска  от 02.10.2020 г. № 1552р., внесение изменений Распоряжение ОА г. Якутска от 01.12.2020 №1871р, внесение изменений Распоряжение ОА г. Якутска от 10.06.2021 №1134р.', N'Расселен по МП', 1, N'10.65', 18, 9, 888.5, NULL, NULL, N'АВАРИЙНЫЙ', N'Распоряжение Окружной администрации города Якутска  от 04.09.2020 г. № 1397р - утратил силу, Распоряжение Окружной администрации города Якутска от 02.10.2020 г. № 1552р - утратил силу; Распоряжение Окружной администрации города Якутска от 01.12.2020 г. № 1871р - утратил силу.', 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8/6', N'Михаила Николаева, 8/6', 62.004678, 129.688106, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'10.65', 5, 13, 207, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'8', N'Михаила Николаева, 8 - 8/7', 61.9939307, 129.6861493, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 13.04.2018 г. №605р', NULL, 0, N'10.65', NULL, 18, 187.6, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Михаила Николаева', N'10/1', N'Михаила Николаева, 10/1', 62.00326, 129.690348, 1, 0, '2024-07-01', N'Распоряжение Окружной администрации города Якутска  от 15.01.2015 г. №20р', N'РАП 2019-2025', 1, N'10.65', 8, 23, 336, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'11/1', N'Михаила Николаева, 11/1', 62.004626, 129.693455, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 12.10.2022 г. №2153р.', NULL, 0, N'68', 9, 31, 246.9, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'24', N'Михаила Николаева, 24', 61.996953, 129.683394, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.10.2022 г. №2217р', NULL, 0, N'14', 9, 14, 296.5, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'24/1', N'Михаила Николаева, 24/1', 61.996953, 129.683394, 1, 0, '2014-10-07', N'Распоряжение Окружной администрации  от 02.07.2014 г.№ 1062р', N'РАП 2019-2025', 1, N'10.65', 17, 2, 600, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'26/1', N'Михаила Николаева, 26/1', 61.993038, 129.681482, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.12.2022 г. № 2665р', NULL, 0, N'14', 8, 20, 566, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'26/2', N'Михаила Николаева, 26/2', 61.993155, 129.680856, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 14.12.2020 г. № 1997р.', NULL, 0, N'14', 41, 101, 1339, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'28/5', N'Михаила Николаева, 28/5', 61.992715, 129.680273, 1, 0, '2017-08-10', N'Распоряжение Окружной администрации города Якутска от 10.01.2017 г. № 17р.', NULL, 1, N'14', 2, 2, 38.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'36/3', N'Михаила Николаева, 36/3', 61.989543, 129.677009, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 04.07.2013 г. №1159р', NULL, 0, N'14', 20, 6, 599.4, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'38/7', N'Михаила Николаева, 38/7', 61.985636, 129.673108, 1, 0, NULL, N'По приказу Министерства строительства Республики Саха (Якутия) от 08.06.2021 г. № 158', NULL, 0, N'14', 8, NULL, 852, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'38/22', N'Михаила Николаева, 38/22', 61.989857, 129.671714, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 16.02.2017 г. №226р', NULL, 0, N'14', 24, 39, 500.6, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Михаила Николаева', N'38/24', N'Михаила Николаева, 38/24', 61.990283, 129.671679, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.04.2017 г. №596р', NULL, 0, N'14', 10, 51, 493.9, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Байкалова', N'5', N'Байкалова, 5', 62.013325, 129.717265, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 05.09.2017 №1475р.', NULL, 0, N'121', 9, 18, 228.7, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Байкалова', N'25', N'Байкалова, 25', 62.012698, 129.71281, 1, 0, '2022-09-28', N'Распоряжение Окружной администрации города Якутска от 28.02.2013 г. №249р', N'РАП 2019-2025', 1, N'121', 6, 16, 156.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Воинская', N'3/1', N'Воинская, д. 3/1', 62.124722, 129.744961, 1, 0, '2021-07-28', N'Распоряжение Окружной администрации города Якутска от 05.10.2016 г. №1680р', N'РАП 2019-2025 (расселяется по ДРЗТ-"СПЗ ДСК 1")', 1, N'153 ДСК', 11, 9, 498.9, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Воинская', N'5', N'Воинская, д. 5', 62.124572, 129.746347, 1, 0, '2019-10-06', N'Распоряжение Окружной администрации города Якутска от 23.10.2015 г. №1830р', N'РАП 2019-2025', 1, N'ДСК', 14, 17, 270, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Воинская', N'7/4', N'Воинская, д. 7/4', 61.983516, 129.656103, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 20.03.2024 г. №401р', NULL, 0, N'ДСК', 17, 26, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Воинская', N'9а', N'Воинская, д. 9а', 61.980752, 129.654228, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 29.04.2020 г. №588р', N'Расселяется по ДРЗТ-"СПЗ ДСК 1"', 1, N'153 ДСК', 14, 9, 250, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'2', N'Дежнева, 2', 62.017093, 129.724967, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 19.12.2022 г. № 2778р', NULL, 0, N'55', 16, 49, 523.6, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'4', N'Дежнева, 4', 62.016965, 129.724228, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 19.12.2022 г. № 2778р', NULL, 0, N'55', 16, 45, 551.8, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'8', N'Дежнева, 8', 62.011385, 129.702689, 1, 0, '2024-12-02', N'Распоряжение Окружной администрации города Якутска от 27.05.2014 г. №851р', N'РАП 2019-2025', 1, N'55', 12, 20, 513.2, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL);

  -- Пакет 351 — 400
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Дежнева', N'75/1', N'Дежнева, 75/1', 62.013526, 129.703689, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 22.03.2024 г. №428р', NULL, 0, N'55', 49, 57, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'77', N'Дежнева, 77', 62.013544, 129.700293, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.09.2023 г. №1670р', NULL, 0, N'68', 16, 47, 506, NULL, NULL, N'АВАРИЙНЫЙ', N'О внес изм в распоряжение Окружной администрации города Якутска от 18.01.2024 г. № 52р', 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'79/1', N'Дежнева, 79/1', 62.012889, 129.699902, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 26.12.2019 г. №2066р', NULL, 0, N'68', 16, 32, 519.2, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'81', N'Дежнева, 81', 62.013191, 129.698414, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 22.07.2021 г. №1443р', NULL, 0, N'68', 16, 36, 547.3, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'81/1', N'Дежнева, 81/1', 62.012731, 129.698818, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'68', 6, 13, 254, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'81/2', N'Дежнева, 81/2', 62.012307, 129.698848, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2018 г. №2578р', NULL, 0, N'68', 5, 16, 281.4, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'81/4', N'Дежнева, 81/4', 62.011396, 129.698784, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 06.12.2022 г. №2632р', NULL, 0, N'68', 16, 18, 573, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'81/5', N'Дежнева, 81/5', 62.011207, 129.698034, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.04.2024 г. №544р', NULL, 0, N'68', 16, 42, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'83', N'Дежнева, 83', 62.012986, 129.697575, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1092р', NULL, 0, N'68', 16, 44, 521.3, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'83/1', N'Дежнева, 83/1', 62.012377, 129.69823, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 19.12.2022 г. № 2780р', NULL, 0, N'68', 12, 26, 492, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'85', N'Дежнева, д. 85', 62.012722, 129.696935, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.12.2022 г. № 2665р', NULL, 0, N'68', 12, 18, 465, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'85/1', N'Дежнева, 85/1', 62.012474, 129.697449, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2021 г. № 1092р', NULL, 0, N'68', 12, 20, 548.3, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'85/3', N'Дежнева, 85/3', 62.012722, 129.696935, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 16.02.2017 г. №226р', NULL, 0, N'68', 16, 13, 413.4, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'87/1', N'Дежнева, 87/1', 62.011705, 129.697045, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.03.2021 г. №448р', NULL, 0, N'68', 12, 28, 609.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Крупской', N'3', N'Крупской, 3', 62.020835, 129.729169, 1, 0, '2022-09-01', N'Распоряжение Окружной администрации города Якутска от 28.02.2013 г. №249р', N'РАП 2019-2025', 1, N'55', 7, 2, 357.6, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Крупской', N'49/3', N'Крупской, 49/3', 62.0109, 129.706808, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 07.06.2023г. №962р', NULL, 0, N'6', 3, 6, 84.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'1', N'Красильникова, д. 1', 62.007546, 129.684056, 1, 0, NULL, NULL, N'Утум-Строй+', 1, N'10.65', 4, 6, 500, NULL, NULL, N'АВАРИЙНЫЙ', N'расселен Утум-Строй+', 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'5/1', N'Красильникова, д. 5/1', 62.006943, 129.68452, 1, 1, NULL, N'Распоряжение администрации города Якутска от 21.09.2022 г. №2006р', N'расселял Горпроект', 1, N'10.65', 4, 7, 136, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Красильникова', N'13', N'Красильникова, д. 13', 62.002523, 129.684738, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 04.06.2020 г. №840р', NULL, 0, N'10.65', 49, NULL, 455, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Крупской', N'14', N'Крупской, д. 14', 62.0042, 129.7106, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 29.05.2018 г. №896р.', NULL, 0, N'124', 12, 28, 267, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ленина', N'63/1', N'Ленина, 63/1', 62.014354, 129.720076, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.03.2022 г. № 536р', NULL, 0, N'117', 2, 1, 99.8, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ленина', N'63/3', N'Ленина, 63/3', 62.013884, 129.720268, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 30.08.2021 г. № 1669р', NULL, 0, N'117', 2, 3, 104.9, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Лизы Чайкиной', N'5', N'Лизы Чайкиной, 5', 62.006966, 129.715076, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 28.12.2021 г. № 2696р', NULL, 0, N'123', 4, 10, 127.5, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Матросова', N'19', N'Матросова, д. 19', 62.008925, 129.70844, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 17.08.2022 г. №1809р', NULL, 0, N'8', 6, NULL, 198, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Строда', N'3', N'Строда, 3', 62.01815, 129.725472, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.07.2023 г. №1249р', NULL, 0, N'55', 2, 12, 127.6, NULL, NULL, N'АВАРИЙНЫЙ', N'О внес изм в распоряжение Окружной администрации города Якутска от 09.01.2024 г. № 9р', 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'17', N'Тимирязева, 17', 62.017046, 129.711778, 1, 0, '2015-01-01', N'Распоряжение Окружной администрации города Якутска от 17.08.2015 г. №1422р', NULL, 1, N'37', 3, 1, 126.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'37', N'Тимирязева, 37', 62.010803, 129.712913, 1, 0, '2024-12-02', N'Распоряжение Окружной администрации города Якутска от 14.04.2014 г. №538р', N'РАП 2019-2025', 1, N'121', 4, 14, 99.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'43/2', N'Тимирязева, 43/2', 62.007532, 129.713327, 1, 0, '2014-01-01', N'Распоряжение Окружной администрации города Якутска от 31.12.2013 г. №2561р', N'РАП 2019-2025', 1, N'122', 8, 15, 59.7, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'55/2', N'Тимирязева, 55/2', 62.003987, 129.712741, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 04.06.2020 г. №840р.', NULL, 0, N'124', 3, 4, 159.40, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'76', N'Тимирязева, д. 76', 62.003448, 129.712481, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска  от 01.09.2022 г. №1907р.', NULL, 0, N'124', 2, 7, 132, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Тимирязева', N'78', N'Тимирязева, 78', 62.002982, 129.712826, 1, 0, '2023-11-29', N'Распоряжение Окружной администрации города Якутска от 29.07.2015 г. №1308р', N'РАП 2019-2025', 1, N'124', 4, 6, 144, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чепалова', N'5', N'Чепалова, 5', 62.019696, 129.726432, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 21.03.2022 г. № 488р', NULL, 0, N'55', 4, 5, 130.3, NULL, NULL, N'АВАРИЙНЫЙ', N'культурное наследение', 0, 0, 0, 0, 0, NULL),
    (N'Чепалова', N'11а', N'Чепалова, д. 11а', 62.018967, 129.715906, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 27.12.2021 г. № 2623р', NULL, 0, N'55', 2, 14, 54, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чепалова', N'21/3', N'Чепалова, 21/3', 62.018912, 129.718746, 1, 0, '2024-07-01', N'Распоряжение Окружной администрации города Якутска от 03.09. 2015 г. №1528р', N'РАП 2019-2025', 1, N'37', 3, 8, 80.6, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чепалова', N'59', N'Чепалова, 59', 62.018243, 129.710197, 1, 0, '2022-09-13', N'Распоряжение Окружной администрации города Якутска от 08.06.2012 г. №2510р', N'расселен по суду', 1, N'7', 2, 2, 81.3, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'26', N'Чернышевского, 26', 62.020121, 129.730503, 1, 0, '2022-11-01', N'Распоряжение Окружной администрации города Якутска  от 30.10.2017 №1810р.', N'МП', 1, N'55', 1, NULL, 108.6, NULL, NULL, N'АВАРИЙНЫЙ', N'памятник культуры, реставрация.', 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'70', N'Чернышевского, 70', 62.007656, 129.718557, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 29.08.2018 г. №1832р', NULL, 0, N'122', 5, 12, 249.2, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'74/6', N'Чернышевского, 74/6', 62.005764, 129.715845, 1, 0, '2024-07-01', N'Распоряжение Окружной администрации города Якутска от 09.06.2015 г. №965р', N'РАП 2019-2025', 1, N'123', 5, 15, 164.60, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'116 к.', N'Чернышевского, 116 к. 1', 62.021944, 129.7341592, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 12.01.2024 г. №33р', NULL, 0, N'11', 4, 15, 134, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Чкалова,56', NULL, N'Чкалова,56', 62.0109322, 129.7181878, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 05.12.2022 г. № 2621р', NULL, 0, N'121', 4, 10, 153.5, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 1, NULL),
    (N'Ярославского', N'36/1', N'Ярославского, 36/1', 62.020192, 129.724721, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 24.12.2020 г. №2081р', NULL, 0, N'55', 3, 6, 129.00, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ярославского', N'45', N'Ярославского, д. 45', 62.020956, 129.725389, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 24.09.2021 г. № 1811р', NULL, 0, N'55', 4, 15, 176, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ярославского', N'45/1', N'Ярославского, 45/1', 62.020341, 129.72574, 1, 0, '2017-08-22', N'Распоряжение Окружной администрации города Якутска от 12.03.2012 г. №1431р', NULL, 1, N'55', 2, 17, 153.2, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Ярославского', N'45/2', N'Ярославского, 45/2', 62.020565, 129.726368, 1, 0, '2023-11-30', N'Распоряжение Окружной администрации города Якутска от 31.12.2013 г. №2561р', N'РАП 2019-2025', 1, N'55', 2, 5, 52.1, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'с. Пригородное, ул. Центральная', N'17', N'с. Пригородное, ул. Центральная, д. 17', 61.822366, 129.633927, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 24.09.2021 г. № 1813р', NULL, 0, N'пригородный', 6, 16, 210.9, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'ул. О.Кошевого', N'10', N'ул. О.Кошевого, 10', 62.008398, 129.709457, 1, 0, '2024-12-09', N'Распоряжение Окружной администрации города Якутска от 22.06.2016 г. №1024р', N'РАП 2019-2025', 1, N'Залог', 2, 13, 777.8, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Байкалова', N'14 корп. 1', N'Байкалова 14 корп. 1', 62.0132442, 129.7143079, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'многоквартирный', NULL, N'Определен', NULL, 0, 1, 0, 0, 1, NULL),
    (N'Воинская д. 2', N'2', N'Воинская д. 2 2', 62.1244595, 129.7461783, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'многоквартирный', NULL, N'Определен', NULL, 0, 1, 0, 0, 1, NULL),
    (N'Воинская д. 4', N'4', N'Воинская д. 4 4', 61.9807523, 129.6542281, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'многоквартирный', NULL, N'Определен', NULL, 0, 1, 0, 0, 1, NULL),
    (N'Птицефабрика', N'4 корп. 1', N'Птицефабрика 4 корп. 1', 62.000971, 129.611222, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'многоквартирный', NULL, N'Определен', NULL, 0, 1, 0, 0, 1, NULL);

  -- Пакет 401 — 406
  INSERT INTO #Staging (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  VALUES
    (N'Пр. М. Николаева', N'36/1 А', N'Пр. М. Николаева 36/1 А', 61.989627, 129.677807, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, N'многоквартирный', NULL, N'Определен', NULL, 0, 1, 0, 0, 0, NULL),
    (N'Птицефабрика', N'1а', N'Птицефабрика 1а', 62.001794, 129.610621, 0, 0, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, N'не определён', NULL, 0, 0, 1, 0, 0, NULL),
    (N'Дежнева', N'85/2', N'Дежнева 85/2', 62.012189, 129.697381, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 06.06.2025 г. № 1062р', NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Дежнева', N'89/2', N'Дежнева 89/2', 62.011729, 129.696262, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 06.06.2025 г. № 1062р', NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'с. Пригородное, ул. Озерная', N'17', N'с. Пригородное, ул. Озерная, д. 17', 61.822366, 129.633927, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 13.01.2025 г. № 15р', NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, N'АВАРИЙНЫЙ', NULL, 0, 0, 0, 0, 0, NULL),
    (N'Чернышевского', N'58а', N'Чернышевского, 58а', 62.010402, 129.720369, 1, 0, NULL, N'Распоряжение Окружной администрации города Якутска от 23.10.2025 г. № 2047р', NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, N'АВАРИЙНЫЙ', N'Маневренный фонд', 0, 0, 0, 0, 0, NULL);

  /* --- UPDATE существующих домов (по совпадению Street + HouseNo) --- */
  -- берём одну запись на каждый (Street, HouseNo) из #Staging через ROW_NUMBER
  -- (в реестре есть дубликаты: один дом записан у нескольких УК)
  -- Если FullAddress вычисляемый — вообще не упоминаем его в SET (иначе ошибка 271)
  DECLARE @is_full_addr_computed BIT = 0;
  SELECT @is_full_addr_computed = CAST(is_computed AS BIT)
    FROM sys.columns
   WHERE object_id = OBJECT_ID(N'dbo.House') AND name = N'FullAddress';
  IF @is_full_addr_computed = 1
    PRINT N'Колонка FullAddress вычисляемая — не упоминаем её в UPDATE (иначе ошибка 271).';

  DECLARE @upd_sql NVARCHAR(MAX);
  SET @upd_sql = N'
  ;WITH src AS (
    SELECT *, ROW_NUMBER() OVER (
      PARTITION BY LTRIM(RTRIM(LOWER(Street))), LTRIM(RTRIM(LOWER(HouseNo)))
      ORDER BY IsEmergency DESC, FullAddress
    ) AS rn
    FROM #Staging
  )
  UPDATE h SET
    Lat               = COALESCE(s.Lat, h.Lat),
    Lon               = COALESCE(s.Lon, h.Lon),
    IsEmergency       = s.IsEmergency,
    IsDemolished      = s.IsDemolished,
    DemolitionDate    = COALESCE(s.DemolitionDate, h.DemolitionDate),
    ActNumber         = COALESCE(s.ActNumber, h.ActNumber),
    RelocationProgram = COALESCE(s.RelocationProgram, h.RelocationProgram),
    IsResettled       = s.IsResettled,
    Quarter           = COALESCE(s.Quarter, h.Quarter),
    FlatsCount        = COALESCE(s.FlatsCount, h.FlatsCount),
    ResidentsCount    = COALESCE(s.ResidentsCount, h.ResidentsCount),
    Area              = COALESCE(s.Area, h.Area),
    HouseType         = COALESCE(s.HouseType, h.HouseType),
    HeatingType       = COALESCE(s.HeatingType, h.HeatingType),
    StatusText        = COALESCE(s.StatusText, h.StatusText),
    Note              = COALESCE(s.Note, h.Note),
    IsAuction         = s.IsAuction,
    IsNoUk            = s.IsNoUk,
    IsUndefined       = s.IsUndefined,
    IsEgrnQuery       = s.IsEgrnQuery,
    CoordsApprox      = CASE WHEN s.CoordsApprox = 1 THEN 1 ELSE ISNULL(h.CoordsApprox, 0) END,
    UKName            = COALESCE(s.UKName, h.UKName)
   FROM dbo.House h
   JOIN src s
     ON LTRIM(RTRIM(LOWER(h.Street))) = LTRIM(RTRIM(LOWER(s.Street)))
    AND LTRIM(RTRIM(LOWER(h.HouseNo))) = LTRIM(RTRIM(LOWER(s.HouseNo)))
    AND s.rn = 1;';
  EXEC sp_executesql @upd_sql;
  SET @updated = @@ROWCOUNT;
  PRINT N'Обновлено существующих домов: ' + CAST(@updated AS NVARCHAR(10)) + N'.';

  /* --- INSERT новых домов (которых ещё нет в dbo.House) --- */
  -- снова берём одну запись на каждый (Street, HouseNo) через ROW_NUMBER
  -- если FullAddress вычисляемый — опускаем его в INSERT
  -- если HouseNo NULL (есть в реестре как «только улица») — пропускаем,
  -- т.к. в dbo.House.HouseNo стоит NOT NULL (выведем их списком)
  DECLARE @no_house_only INT = 0;
  SELECT @no_house_only = COUNT(*) FROM #Staging WHERE HouseNo IS NULL;
  IF @no_house_only > 0
  BEGIN
    PRINT N'Дома без номера (только улица) — пропущены в INSERT (HouseNo NOT NULL в dbo.House):';
    DECLARE skip_cur CURSOR LOCAL FAST_FORWARD FOR
      SELECT DISTINCT Street FROM #Staging WHERE HouseNo IS NULL;
    DECLARE @skip_street NVARCHAR(100);
    OPEN skip_cur;
    FETCH NEXT FROM skip_cur INTO @skip_street;
    WHILE @@FETCH_STATUS = 0
    BEGIN
      PRINT N'  только улица, без номера: ' + ISNULL(@skip_street, N'?');
      FETCH NEXT FROM skip_cur INTO @skip_street;
    END
    CLOSE skip_cur;
    DEALLOCATE skip_cur;
  END

  DECLARE @ins_sql NVARCHAR(MAX);
  IF @is_full_addr_computed = 1
  BEGIN
    SET @ins_sql = N'
  ;WITH src AS (
    SELECT *, ROW_NUMBER() OVER (
      PARTITION BY LTRIM(RTRIM(LOWER(Street))), LTRIM(RTRIM(LOWER(HouseNo)))
      ORDER BY IsEmergency DESC, FullAddress
    ) AS rn
    FROM #Staging
    WHERE HouseNo IS NOT NULL  -- пропускаем записи без номера дома
  )
  INSERT INTO dbo.House (Street, HouseNo, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  SELECT s.Street, s.HouseNo, s.Lat, s.Lon, s.IsEmergency, s.IsDemolished, s.DemolitionDate, s.ActNumber, s.RelocationProgram, s.IsResettled, s.Quarter, s.FlatsCount, s.ResidentsCount, s.Area, s.HouseType, s.HeatingType, s.StatusText, s.Note, s.IsAuction, s.IsNoUk, s.IsUndefined, s.IsEgrnQuery, s.CoordsApprox, s.UKName
   FROM src s
  WHERE s.rn = 1
    AND NOT EXISTS (
    SELECT 1 FROM dbo.House h
    WHERE LTRIM(RTRIM(LOWER(h.Street))) = LTRIM(RTRIM(LOWER(s.Street)))
      AND LTRIM(RTRIM(LOWER(h.HouseNo))) = LTRIM(RTRIM(LOWER(s.HouseNo))));';
    PRINT N'FullAddress вычисляемый — INSERT без него (адрес посчитается автоматически).';
  END
  ELSE
  BEGIN
    SET @ins_sql = N'
  ;WITH src AS (
    SELECT *, ROW_NUMBER() OVER (
      PARTITION BY LTRIM(RTRIM(LOWER(Street))), LTRIM(RTRIM(LOWER(HouseNo)))
      ORDER BY IsEmergency DESC, FullAddress
    ) AS rn
    FROM #Staging
    WHERE HouseNo IS NOT NULL  -- пропускаем записи без номера дома
  )
  INSERT INTO dbo.House (Street, HouseNo, FullAddress, Lat, Lon, IsEmergency, IsDemolished, DemolitionDate, ActNumber, RelocationProgram, IsResettled, Quarter, FlatsCount, ResidentsCount, Area, HouseType, HeatingType, StatusText, Note, IsAuction, IsNoUk, IsUndefined, IsEgrnQuery, CoordsApprox, UKName)
  SELECT s.Street, s.HouseNo, s.FullAddress, s.Lat, s.Lon, s.IsEmergency, s.IsDemolished, s.DemolitionDate, s.ActNumber, s.RelocationProgram, s.IsResettled, s.Quarter, s.FlatsCount, s.ResidentsCount, s.Area, s.HouseType, s.HeatingType, s.StatusText, s.Note, s.IsAuction, s.IsNoUk, s.IsUndefined, s.IsEgrnQuery, s.CoordsApprox, s.UKName
   FROM src s
  WHERE s.rn = 1
    AND NOT EXISTS (
    SELECT 1 FROM dbo.House h
    WHERE LTRIM(RTRIM(LOWER(h.Street))) = LTRIM(RTRIM(LOWER(s.Street)))
      AND LTRIM(RTRIM(LOWER(h.HouseNo))) = LTRIM(RTRIM(LOWER(s.HouseNo))));';
  END
  EXEC sp_executesql @ins_sql;
  SET @inserted = @@ROWCOUNT;
  PRINT N'Вставлено новых домов: ' + CAST(@inserted AS NVARCHAR(10)) + N'.';
  PRINT N'Обновлено/вставлено домов всего: ' + CAST(@updated + @inserted AS NVARCHAR(10)) + N' (с координатами).';


  /* --- ШАГ 4: привязка House.UKID к dbo.UK по совпадению названия --- */
  UPDATE h SET h.UKID = u.UKID
   FROM dbo.House h
   JOIN dbo.UK u ON LTRIM(RTRIM(LOWER(h.UKName))) = LTRIM(RTRIM(LOWER(u.Name)))
  WHERE h.UKName IS NOT NULL;
  PRINT N'Привязка домов к УК выполнена: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + N' домов.';


  -- статистика после обновления
  DECLARE @total INT = (SELECT COUNT(*) FROM dbo.House);
  DECLARE @em INT = (SELECT COUNT(*) FROM dbo.House WHERE IsEmergency = 1);
  DECLARE @dem INT = (SELECT COUNT(*) FROM dbo.House WHERE IsDemolished = 1);
  DECLARE @res INT = (SELECT COUNT(*) FROM dbo.House WHERE IsResettled = 1);
  DECLARE @auc INT = (SELECT COUNT(*) FROM dbo.House WHERE IsAuction = 1);
  DECLARE @nouk INT = (SELECT COUNT(*) FROM dbo.House WHERE IsNoUk = 1);
  DECLARE @map INT = (SELECT COUNT(*) FROM dbo.House WHERE Lat IS NOT NULL AND Lon IS NOT NULL AND IsDemolished = 0);
  PRINT N'── Статистика после миграции 11 ──';
  PRINT N'Всего домов в базе: ' + CAST(@total AS NVARCHAR(10));
  PRINT N'  аварийных: ' + CAST(@em AS NVARCHAR(10));
  PRINT N'  снесённых: ' + CAST(@dem AS NVARCHAR(10));
  PRINT N'  расселённых: ' + CAST(@res AS NVARCHAR(10));
  PRINT N'  на аукционе: ' + CAST(@auc AS NVARCHAR(10));
  PRINT N'  без УК: ' + CAST(@nouk AS NVARCHAR(10));
  PRINT N'  видно на карте (с координатами, не снесённые): ' + CAST(@map AS NVARCHAR(10));

  COMMIT TRANSACTION;
  PRINT N'Миграция 11 завершена успешно.';
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
  PRINT N'ОШИБКА миграции 11: ' + ERROR_MESSAGE();
  THROW;
END CATCH;
GO