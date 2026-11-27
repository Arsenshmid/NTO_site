-- ============================================================
-- 12_nto_attention.sql — «Требует внимания» для НТО (NtoDB!)
-- ============================================================
-- Запускать в базе NtoDB (НЕ AvtodorDB!).
--
-- ВНИМАНИЕ: сайт добавит эти колонки АВТОМАТИЧЕСКИ при первом
-- запуске (тот же приём, что и IsHiddenFromMap у МКД). Этот файл
-- нужен только «для порядка» — если хотите подготовить базу руками,
-- или для бэкапа структуры. Отдельно выполнять НЕ обязательно.
--
-- Что даёт:
--   IsAttention   — «требует внимания» (❗ на карте, в списке и карточке);
--   AttentionNote — заметка, ЗА ЧТО требует внимания
--                  (например: «Водник, 19.11 приезжали лично — компромисс:
--                  остановка-павильон с водокачкой 19 л»).
--
-- Кнопки «❗ Требует внимания» / «✓ Снять» появляются:
--   в попапе точки на карте и в карточке НТО (войдя как editor/admin).
-- Заметка пишется в журнал изменений (nto_journal), как все правки.

IF COL_LENGTH('dbo.nto_object', 'IsAttention') IS NULL
    ALTER TABLE dbo.nto_object ADD IsAttention BIT NOT NULL DEFAULT 0;
GO

IF COL_LENGTH('dbo.nto_object', 'AttentionNote') IS NULL
    ALTER TABLE dbo.nto_object ADD AttentionNote NVARCHAR(500) NULL;
GO

-- Проверка (не обязательно):
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'nto_object' AND COLUMN_NAME IN ('IsAttention', 'AttentionNote');
