/* =====================================================================
   МИГРАЦИЯ 09: координаты (lat/lon) для всех НТО из базы данных.
   Выполнять в SSMS при подключении к базе NtoDB.
   Координаты собраны из: ссылок 2ГИС, адресов в данных, OpenStreetMap
   (Overpass/Nominatim), Яндекс.Карт. Для 8 объектов вне схемы адрес
   вообще не указан в исходных файлах — для них координат нет.

   Скрипт можно запускать ПОВТОРНО: он заполняет только пустые lat/lon
   (не перезаписывает уже заполненные вручную значения и данные миграции 08).
   ===================================================================== */
SET NOCOUNT ON;
PRINT N'Начата миграция 09 (координаты НТО)...';

UPDATE dbo.nto_object SET lat = 62.027154, lon = 129.731808, updated_at = SYSDATETIME() WHERE scheme_num = N'1' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.006687, lon = 129.669966, updated_at = SYSDATETIME() WHERE scheme_num = N'2' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.011836, lon = 129.695826, updated_at = SYSDATETIME() WHERE scheme_num = N'3' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.005438, lon = 129.71337, updated_at = SYSDATETIME() WHERE scheme_num = N'4' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.00483, lon = 129.713925, updated_at = SYSDATETIME() WHERE scheme_num = N'5' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.997622, lon = 129.615715, updated_at = SYSDATETIME() WHERE scheme_num = N'6' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.006391, lon = 129.692214, updated_at = SYSDATETIME() WHERE scheme_num = N'7' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.002774, lon = 129.679374, updated_at = SYSDATETIME() WHERE scheme_num = N'8' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.993188, lon = 129.683547, updated_at = SYSDATETIME() WHERE scheme_num = N'9' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.993188, lon = 129.683547, updated_at = SYSDATETIME() WHERE scheme_num = N'10' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.988537, lon = 129.680082, updated_at = SYSDATETIME() WHERE scheme_num = N'11' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.982047, lon = 129.661922, updated_at = SYSDATETIME() WHERE scheme_num = N'12' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.982047, lon = 129.661922, updated_at = SYSDATETIME() WHERE scheme_num = N'13' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.982796, lon = 129.663105, updated_at = SYSDATETIME() WHERE scheme_num = N'14' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.983218, lon = 129.658035, updated_at = SYSDATETIME() WHERE scheme_num = N'15' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.982612, lon = 129.659594, updated_at = SYSDATETIME() WHERE scheme_num = N'16' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.982796, lon = 129.663105, updated_at = SYSDATETIME() WHERE scheme_num = N'17' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.036584, lon = 129.632021, updated_at = SYSDATETIME() WHERE scheme_num = N'18' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.000656, lon = 129.613304, updated_at = SYSDATETIME() WHERE scheme_num = N'19' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.996907, lon = 129.615991, updated_at = SYSDATETIME() WHERE scheme_num = N'20' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.996523, lon = 129.710982, updated_at = SYSDATETIME() WHERE scheme_num = N'21' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.996523, lon = 129.710982, updated_at = SYSDATETIME() WHERE scheme_num = N'22' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.997994, lon = 129.705613, updated_at = SYSDATETIME() WHERE scheme_num = N'23' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.997994, lon = 129.705613, updated_at = SYSDATETIME() WHERE scheme_num = N'24' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.992691, lon = 129.686171, updated_at = SYSDATETIME() WHERE scheme_num = N'25' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.983218, lon = 129.658035, updated_at = SYSDATETIME() WHERE scheme_num = N'26' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.013191, lon = 129.698414, updated_at = SYSDATETIME() WHERE scheme_num = N'27' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.906921, lon = 129.639043, updated_at = SYSDATETIME() WHERE scheme_num = N'28' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.005891, lon = 129.692511, updated_at = SYSDATETIME() WHERE scheme_num = N'29' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.996523, lon = 129.710982, updated_at = SYSDATETIME() WHERE scheme_num = N'30' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.893375, lon = 129.513112, updated_at = SYSDATETIME() WHERE scheme_num = N'31' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.001764, lon = 129.616138, updated_at = SYSDATETIME() WHERE scheme_num = N'32' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.990336, lon = 129.682171, updated_at = SYSDATETIME() WHERE scheme_num = N'33' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.996523, lon = 129.710982, updated_at = SYSDATETIME() WHERE scheme_num = N'34' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.987877, lon = 129.683125, updated_at = SYSDATETIME() WHERE scheme_num = N'35' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.98411, lon = 129.652682, updated_at = SYSDATETIME() WHERE scheme_num = N'36' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.989547, lon = 129.635984, updated_at = SYSDATETIME() WHERE scheme_num = N'37' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.005803, lon = 129.683568, updated_at = SYSDATETIME() WHERE scheme_num = N'38' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.020187, lon = 129.718466, updated_at = SYSDATETIME() WHERE scheme_num = N'39' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.005824, lon = 129.682945, updated_at = SYSDATETIME() WHERE scheme_num = N'40' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.984209, lon = 129.651771, updated_at = SYSDATETIME() WHERE scheme_num = N'41' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.892266, lon = 129.512829, updated_at = SYSDATETIME() WHERE scheme_num = N'42' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.997622, lon = 129.615715, updated_at = SYSDATETIME() WHERE scheme_num = N'43' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.980381, lon = 129.650355, updated_at = SYSDATETIME() WHERE scheme_num = N'44' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.98191, lon = 129.671837, updated_at = SYSDATETIME() WHERE scheme_num = N'45' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.974614, lon = 129.62893, updated_at = SYSDATETIME() WHERE scheme_num = N'46' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.98191, lon = 129.671837, updated_at = SYSDATETIME() WHERE scheme_num = N'47' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.989743, lon = 129.700072, updated_at = SYSDATETIME() WHERE scheme_num = N'48' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 61.98191, lon = 129.671837, updated_at = SYSDATETIME() WHERE scheme_num = N'49' AND is_deleted = 0 AND lat IS NULL AND lon IS NULL;
UPDATE dbo.nto_object SET lat = 62.003509, lon = 129.6956, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 11/6а ст1';
UPDATE dbo.nto_object SET lat = 61.998919, lon = 129.681682, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Улица им. Д.Д. Красильникова, 18/2';
UPDATE dbo.nto_object SET lat = 61.997754, lon = 129.7046, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/vwTGt';
UPDATE dbo.nto_object SET lat = 61.981653, lon = 129.661945, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'михаила николаева 42а (емеян)';
UPDATE dbo.nto_object SET lat = 62.008666, lon = 129.632602, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/TDf72';
UPDATE dbo.nto_object SET lat = 62.003509, lon = 129.6956, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 11/6а ст1';
UPDATE dbo.nto_object SET lat = 61.998919, lon = 129.681682, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Улица им. Д.Д. Красильникова, 18/2';
UPDATE dbo.nto_object SET lat = 62.010617, lon = 129.681181, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'3 поликлинка теплая остановка';
UPDATE dbo.nto_object SET lat = 62.006266, lon = 129.718368, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'62.006266, 129.718368 https://2gis.ru/yakutsk/search/62.006266%2C%20129.718368/geo/70030076742099526/129.718331%2C62.006257?m=129.718518%2C62.006221%2F20%2Fp%2F45%2Fr%2F-10.82';
UPDATE dbo.nto_object SET lat = 62.020187, lon = 129.718466, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'​Улица Крупской, 19/1';
UPDATE dbo.nto_object SET lat = 61.982113, lon = 129.6588, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/9zCr6';
UPDATE dbo.nto_object SET lat = 62.005377, lon = 129.713126, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'62.005377, 129.713126';
UPDATE dbo.nto_object SET lat = 61.997062, lon = 129.615312, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'61.997062, 129.615312 https://2gis.ru/yakutsk/search/%D0%BF%D1%82%D0%B8%D1%86%D0%B5%D1%84%D0%B0%D0%B1%D1%80%D0%B8%D0%BA%D0%B0%2016/geo/70030077192687892/129.615312%2C61.997062?m=129.616097%2C61.997216%2F18.45%2Fp%2F42.3%2Fr%2F-12.44';
UPDATE dbo.nto_object SET lat = 61.980795, lon = 129.666049, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 53/1г';
UPDATE dbo.nto_object SET lat = 61.981793, lon = 129.663453, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 42а';
UPDATE dbo.nto_object SET lat = 62.036584, lon = 129.632021, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'​Сергеляхское шоссе 8 километр, 1';
UPDATE dbo.nto_object SET lat = 62.001794, lon = 129.610621, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Птицефабрика, 1в';
UPDATE dbo.nto_object SET lat = 62.005083, lon = 129.677716, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Сергеляхское шоссе 4 километр, 27';
UPDATE dbo.nto_object SET lat = 61.983038, lon = 129.674352, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 41г';
UPDATE dbo.nto_object SET lat = 62.001312, lon = 129.691257, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/s2YYO';
UPDATE dbo.nto_object SET lat = 62.007549, lon = 129.67611, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/ot64L';
UPDATE dbo.nto_object SET lat = 62.008022, lon = 129.677685, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/i8e3N';
UPDATE dbo.nto_object SET lat = 62.008022, lon = 129.677685, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/Vucwg';
UPDATE dbo.nto_object SET lat = 62.008022, lon = 129.677685, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/iLrFy';
UPDATE dbo.nto_object SET lat = 62.012023, lon = 129.696544, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/zq6Rj';
UPDATE dbo.nto_object SET lat = 62.013666, lon = 129.698157, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/70YTb';
UPDATE dbo.nto_object SET lat = 61.999405, lon = 129.683025, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/8Ilhn';
UPDATE dbo.nto_object SET lat = 62.002774, lon = 129.679374, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Улица им. Д.Д. Красильникова, 45 бокс 22';
UPDATE dbo.nto_object SET lat = 62.003077, lon = 129.681868, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/E6r7T';
UPDATE dbo.nto_object SET lat = 62.013561, lon = 129.698195, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Улица Дежнёва, 78а';
UPDATE dbo.nto_object SET lat = 62.01709, lon = 129.718655, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/kdJig';
UPDATE dbo.nto_object SET lat = 61.987877, lon = 129.683125, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(REPLACE(address, CHAR(13), ''))) = N'Проспект Михаила Николаева, 31Б';
UPDATE dbo.nto_object SET lat = 61.999294, lon = 129.711079, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/yrzLs';
UPDATE dbo.nto_object SET lat = 61.98846, lon = 129.682624, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/ECF6f';
UPDATE dbo.nto_object SET lat = 62.00914, lon = 129.713494, updated_at = SYSDATETIME() WHERE is_deleted = 0 AND lat IS NULL AND lon IS NULL AND LTRIM(RTRIM(map_url)) = N'https://go.2gis.com/dF34I';

DECLARE @n INT;
SELECT @n = COUNT(*) FROM dbo.nto_object WHERE lat IS NOT NULL AND lon IS NOT NULL AND is_deleted = 0;
PRINT N'НТО с координатами после миграции: ' + CAST(@n AS NVARCHAR(10)) + N' из 92.';
PRINT N'Миграция 09 завершена.';
