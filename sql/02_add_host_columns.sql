-- Миграция 02: добавить колонки host_ip и host_name в nto_journal
-- БЕЗОПАСНО: если колонки уже есть, ничего не делает.
USE NtoDB;
GO
IF COL_LENGTH('dbo.nto_journal','host_ip') IS NULL
BEGIN
    ALTER TABLE dbo.nto_journal ADD host_ip NVARCHAR(50) NULL;
    PRINT N'Добавлена колонка host_ip в nto_journal';
END
GO
IF COL_LENGTH('dbo.nto_journal','host_name') IS NULL
BEGIN
    ALTER TABLE dbo.nto_journal ADD host_name NVARCHAR(100) NULL;
    PRINT N'Добавлена колонка host_name в nto_journal';
END
GO
PRINT N'Миграция 02 завершена.';
