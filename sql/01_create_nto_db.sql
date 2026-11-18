-- Создание базы НТО. Скрипт БЕЗОПАСНЫЙ: если таблицы уже есть, он остановится и ничего не сотрёт.
IF DB_ID(N'NtoDB') IS NULL CREATE DATABASE NtoDB;
GO
USE NtoDB;
GO
IF OBJECT_ID(N'dbo.nto_object') IS NOT NULL
BEGIN
    RAISERROR(N'ОСТАНОВКА: таблицы НТО уже существуют. Ничего не изменено.',16,1) ;
    SET NOEXEC ON;
END
GO
CREATE TABLE dbo.nto_object (
    id            INT IDENTITY(1,1) PRIMARY KEY,
    in_scheme     BIT NOT NULL DEFAULT 1,          -- 1 = в схеме, 0 = вне схемы
    scheme_num    NVARCHAR(20)  NULL,              -- № в схеме
    address       NVARCHAR(500) NULL,              -- местонахождение
    address_alt   NVARCHAR(500) NULL,              -- соседний адрес
    map_url       NVARCHAR(500) NULL,              -- ссылка на карту
    lat           DECIMAL(9,6)  NULL,              -- координаты (для будущей карты)
    lon           DECIMAL(9,6)  NULL,
    area          NVARCHAR(50)  NULL,              -- площадь объекта
    authority     NVARCHAR(300) NULL,              -- орган, осуществляющий полномочия собственника
    owner_name    NVARCHAR(500) NULL,              -- юр./физ. лицо
    inn           NVARCHAR(12)  NULL,
    ogrn          NVARCHAR(15)  NULL,              -- ОГРН / ОГРНИП
    fns_status    NVARCHAR(200) NULL,              -- статус по ФНС
    fns_date      DATE          NULL,              -- дата сверки с ФНС
    obj_kind      NVARCHAR(200) NULL,              -- вид НТО
    trade_type    NVARCHAR(200) NULL,              -- вид торговли
    specialization NVARCHAR(500) NULL,
    trade_area    NVARCHAR(50)  NULL,              -- размер торговой площади
    term_text     NVARCHAR(300) NULL,              -- срок размещения как в документе
    term_start    DATE NULL,
    term_end      DATE NULL,
    conditions    NVARCHAR(1000) NULL,             -- условия (договор №, дата)
    notes         NVARCHAR(2000) NULL,             -- примечания
    contract_state NVARCHAR(30) NULL,              -- ручная отметка состояния (если нужно перекрыть расчёт)
    chk_contract  NVARCHAR(500) NULL,              -- проверка: договор
    chk_kkt       NVARCHAR(500) NULL,              -- проверка ККТ
    chk_match     NVARCHAR(500) NULL,              -- соответствие заявленного вида
    chk_compare   NVARCHAR(500) NULL,              -- сличение
    chk_kupavy    NVARCHAR(500) NULL,              -- столбец «купавы» из исходного файла
    phone         NVARCHAR(500) NULL,
    comment       NVARCHAR(2000) NULL,             -- комментарий проверки
    src           NVARCHAR(200) NULL,              -- источник (файл, строка)
    is_deleted    BIT NOT NULL DEFAULT 0,
    created_at    DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    updated_at    DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX ix_nto_inn ON dbo.nto_object(inn);
CREATE TABLE dbo.nto_file (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    object_id   INT NOT NULL REFERENCES dbo.nto_object(id),
    file_name   NVARCHAR(300) NOT NULL,            -- имя как у пользователя
    stored_name NVARCHAR(100) NOT NULL,            -- имя на диске
    caption     NVARCHAR(300) NULL,
    is_photo    BIT NOT NULL DEFAULT 0,
    size_bytes  INT NULL,
    uploaded_by NVARCHAR(50) NULL,
    uploaded_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    is_deleted  BIT NOT NULL DEFAULT 0
);
CREATE TABLE dbo.nto_journal (
    id         INT IDENTITY(1,1) PRIMARY KEY,
    at         DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    user_name  NVARCHAR(50) NULL,
    action     NVARCHAR(30) NOT NULL,
    object_id  INT NULL,
    before_val NVARCHAR(MAX) NULL,
    after_val  NVARCHAR(MAX) NULL
);
GO
SET NOEXEC OFF;
PRINT N'Готово: база NtoDB и таблицы созданы.';
