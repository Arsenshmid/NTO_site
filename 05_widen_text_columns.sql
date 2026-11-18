-- Миграция 05: расширить столбец authority в nto_object с NVARCHAR(300) до NVARCHAR(1000).
-- Причина: туда иногда попадают длинные тексты из выписок ЕГРН, и сохранение падает с ошибкой усечения.
USE NtoDB;
GO
IF COL_LENGTH('dbo.nto_object','authority') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_object ALTER COLUMN authority NVARCHAR(1000) NULL;
    PRINT N'Столбец authority расширен до NVARCHAR(1000)';
END
GO
-- Также расширяем notes и conditions — там тоже бывают длинные тексты
IF COL_LENGTH('dbo.nto_object','conditions') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_object ALTER COLUMN conditions NVARCHAR(2000) NULL;
    PRINT N'Столбец conditions расширен до NVARCHAR(2000)';
END
IF COL_LENGTH('dbo.nto_object','notes') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_object ALTER COLUMN notes NVARCHAR(4000) NULL;
    PRINT N'Столбец notes расширен до NVARCHAR(4000)';
END
IF COL_LENGTH('dbo.nto_object','comment') IS NOT NULL
BEGIN
    ALTER TABLE dbo.nto_object ALTER COLUMN comment NVARCHAR(4000) NULL;
    PRINT N'Столбец comment расширен до NVARCHAR(4000)';
END
PRINT N'Миграция 05 завершена.';
