-- Миграция 04: создать таблицу активных сессий для показа "кто сейчас на сайте".
-- Реально активные сессии хранятся в памяти Python-приложения (глобальный словарь),
-- эта таблица нужна только для постоянной истории входов (кто, когда, с какого IP).
USE NtoDB;
GO
IF OBJECT_ID(N'dbo.nto_session_log') IS NULL
BEGIN
    CREATE TABLE dbo.nto_session_log (
        id          INT IDENTITY(1,1) PRIMARY KEY,
        user_name   NVARCHAR(50)  NULL,    -- кто вошёл (NULL = аноним)
        host_ip     NVARCHAR(50)  NULL,    -- IP-адрес
        host_name   NVARCHAR(100) NULL,    -- имя компьютера, если удалось определить
        action      NVARCHAR(20)  NOT NULL, -- 'login' / 'logout' / 'pageview'
        page        NVARCHAR(100) NULL,    -- какую страницу открыл
        at          DATETIME2 NOT NULL DEFAULT SYSDATETIME()
    );
    PRINT N'Создана таблица nto_session_log';
END
GO
PRINT N'Миграция 04 завершена.';
