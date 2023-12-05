# Интеграция данных Метрики Про в Yandex Cloud
Приведенное ниже решение описывает интеграцию и работу с данными Метрики в Yandex Cloud. При создании инструкции использованы материалы с сайтов Яндекс Метрики[^1],[^2] и Yandex Cloud[^3].

> [!IMPORTANT]
> Передача данных из источника Яндекс Метрика возможна при подключении пакета [Метрика Про](https://yandex.ru/support/metrica/pro/intro.html).

## История изменений
- 2023-12-05 v01 Первая редакция
***
***

## Описание работы решения

### Схема работы с данными Метрики про Yandex Cloud
![metrica-pro-yc](img/metrica-pro-yc.png?raw=true "Схема работы с данными Метрики про Yandex Cloud")

### Применяемые сервисы
1. [Yandex Data Transfer](https://cloud.yandex.ru/services/data-transfer) для передачи данных Метрики в облако
1. [Managed Service for ClickHouse](https://cloud.yandex.ru/services/managed-clickhouse) в качестве буферной зоны и источника данных для Datalens
1. [Yandex Datalens](https://cloud.yandex.ru/services/datalens) для визуализации данных
1. [Yandex Object Storage](https://cloud.yandex.ru/services/storage) для хранения данных в файловом формате
1. [Yandex Query](https://cloud.yandex.ru/services/query) для ad-hoc анализа данных при помощи языка YQL
***
***
### Шаги по созданию решения
1. Настройка инфраструктуры
    1. Подготовка кластера ClickHouse
    1. Настройка endpoint'ов подключения к Метрике и ClickHouse
    1. Настройка и активация трансфера
1. Визуализация данных Метрики в Datalens
1. Выгрузка данных в Yandex Object Storage (S3)
1. Работа с данными Метрики при помощи Yandex Query

***
***

# Настройка инфраструктуры

Для быстрой настройки инфраструктуры вы можете воспользоваться скриптами из каталога [terraform](/terraform). В terraform-скриптах описана вся инфраструктура за исключением endpoint'а Метрики и самого трансфера, которые на момент публикации (декабрь 2023) не поддержаны в провайдере, и их потребуется создать через веб-интерфейс.

# Создание кластера ClickHouse

Если у вас нет кластера ClickHouse, вы можете создать его в вашем облаке при помощи terraform-скрипта, через утилиту YC и UI-консоль Yandex Cloud. Подробное описание работы с кластерами ClickHouse приведены на странице управляемого сервиса ClickHouse[^4]. 

## Настройка endpoint'ов подключения к Метрике и ClickHouse
Создайте endpoint'ы подключения для источника Метрика:
![metrica-source](img/metrica-source.png?raw=true "Создание endpoint'а подключения к Метрике")

\- и приемника Clickhouse:
![clickhouse-target](img/clickhouse-target.png?raw=true "Создание endpoint'а подключения к Clickhouse")

Источник Метрика поставляет 2 таблицы - с визитами (visits) и хитами (hits).
Стоит обратить внимание, что в случае отсутствия таблиц в приемнике Data Transfer создаст таблицу самостоятельно в соответствии с настройками шардирования приемника. Если вы хотите задать топологию таблиц, создайте их до активации трансфера и в свойствах endpoint'а укажите политику очистки "Truncate" или "Не очищать".

Трансфер из Метрики работает в режиме репликации, и мы рекомендуем выбирать политику "Не очищать", т.к. если вы по какой-то причине захотите деактивировать трансфер, то при повторной активации данные предыдущего запуска сохранятся.

## Настройка и активация трансфера

Создайте трансфер
![transfer-create](img/transfer-create.png?raw=true "Создание трансфера")

Далее активируйте его и проверьте наличие данных в приемнике:
![clickhouse-hits-select](img/clickhouse-hits-select.png?raw=true "Данные таблицы hits")
Обратите внимание, что Data transfer добавляет идентификатор трансфера в имена таблиц при их создании.

# Визуализация данных Метрики в Datalens

В качестве примера рассмотрим описанные на сайте Метрики[^2] типовые запросы к данным.
Необходимо создать подключение к кластеру ClickHouse, после чего можно приступить к созданию QL-чартов.

## Чарт Посещаемость
```sql
/*
https://yandex.ru/support/metrica/pro/data-work.html#data-work__traffic

- не забыть указать корректное имя таблицы в своей БД
- id счетчика можно убрать
- на вкладке параметр создать параметр с именем "interval" и типом date-interval
*/ 

SELECT StartDate AS `ym:s:date`, 
        sum(Sign) AS `ym:s:visits` -- правильное коллапсирование нескольких версий визита в самую последнюю и актуальную, и подсчет количества визитов
from 
metrica_copy.visits_<id трансфера>
as `default.visits_all` 
WHERE `ym:s:date` >= {{interval_from}} -- исторические данные до момента создания коннектора в данной версии не поддерживаются
        and `ym:s:date` <= {{interval_to}} -- данные за "сегодня" (и медленные обновления за более поздние дни, например, оффлайн конверсии) могут доезжать с опозданием относительно интерфейса
GROUP BY `ym:s:date` 
WITH TOTALS  
HAVING `ym:s:visits` >= 0.0 
ORDER BY `ym:s:date` ASC 
limit 0,10
```

![datalens-chart-visits](img/datalens-chart-visits.png?raw=true "Чарт Посещаемость")

## Чарт Источники трафика

```sql
/*
https://yandex.ru/support/metrica/pro/data-work.html#data-work__utm

- не забыть указать корректное имя таблицы в своей БД
- id счетчика можно убрать
- на вкладке Параметры создать параметр с именем "interval" и типом date-interval
*/ 

SELECT
    `TrafficSource.UTMSource`[indexOf(`TrafficSource.Model`, 2)] AS `ym:s:lastSignUTMSource`,
    sum(Sign) AS `ym:s:visits`,
    least(uniqExact(CounterUserIDHash), `ym:s:visits`) AS `ym:s:users`,
    100. * (sum(IsBounce * Sign) / `ym:s:visits`) AS `ym:s:bounceRate`,
    sum(PageViews * Sign) / `ym:s:visits` AS `ym:s:pageDepth`,
    sum(Duration * Sign) / `ym:s:visits` AS `ym:s:avgVisitDurationSeconds`,
    sumArray(arrayMap(x -> (if(isFinite(x), x, 0) * Sign), arrayMap(x_0 -> toInt64(notEmpty(x_0)), `EPurchase.ID`))) AS `ym:s:ecommercePurchases`
FROM metrica_copy.visits_<id трансфера>  -- сюда вставить свою базу и свою таблицу визитов
WHERE (StartDate >= {{interval_from}})
        AND (StartDate <= {{interval_to}} ) 
        AND (`ym:s:lastSignUTMSource` != '')
GROUP BY `ym:s:lastSignUTMSource`
HAVING (`ym:s:visits` > 0.) OR (`ym:s:users` > 0.) OR (`ym:s:ecommercePurchases` > 0.)
ORDER BY
    `ym:s:visits` DESC,
    `ym:s:lastSignUTMSource` ASC
LIMIT 0, 50
```

![datalens-chart-utmsources](img/datalens-chart-utmsources.png?raw=true "Чарт Источники трафика")

## Дашборд
Добавьте чарты на дашборд и заведите параметр с именем "interval" (Вкладка "Ручной ввод", тип "Календарь" и флажок "Диапазон"):
![datalens-dashboard](img/datalens-dashboard.png?raw=true "Дашборд Метрика")


# Выгрузка данных в Yandex Object Storage

Для возможности выгрузки данных в Object Storage необходимость настроить доступ из кластера Clickhouse[^5].

После настройки доступа вы сможете выгружать данные в объектное хранилище при помощи встроенного в Clickhouse табличного движка S3:

```sql
/* создание S3-таблицы. подставтье свои значения для id кластера, id трансфера и имя S3 bucket'а */

create table metrica.hits_s3 on cluster <id кластера> as hits_<id трансфера>
ENGINE = S3('https://storage.yandexcloud.net/<имя s3 bucket-а>/metrica/hits/hits.csv.gz',
 'CSVWithNames', 'gzip')
SETTINGS input_format_with_names_use_header = 1;


/* вставка данных в s3-таблицу */
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<id трансфера> where EventDate=cast('2023-11-01' as date);
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<id трансфера> where EventDate=cast('2023-11-02' as date);
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<id трансфера> where EventDate=cast('2023-11-03' as date);

/* проверим пути выгруженных файлов */
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-01' as date) limit 1
union all
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-02' as date) limit 1
union all
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-03' as date) limit 1
```

![clickhouse-s3-table](img/clickhouse-s3-table.png?raw=true "S3-таблица")

```sql
/* сравним исходную и S3-таблицу */
select 's3' as storage, count(1) as cnt from hits_s3
union all 
select 'ch' as storage, count(1) as cnt from hits_<id трансфера> where EventDate between cast('2023-11-01' as date) and cast('2023-11-03' as date);

storage|cnt    |
-------+-------+
ch     |3902732|
s3     |3902732|
```
> [!IMPORTANT]
> Если вы будете выгружать в Object storage слишком большие порции данных, то можете получить ошибку по таймауту. Чтобы избежать ошибки, увеличьте значение параметра драйвера `socket_timeout` или разбейте порцию данных для выгрузки несколькими запросами с фильтром `WHERE`.

Помимо явной выгрузки в Object Storage с возможностью последующей работы с данными при помощи других инструментов, в Yandex Cloud поддержан режим гибридного хранилища для Managed ClickHouse. Настроив автоматический перенос данных в гибридное хранилище при помощи конструкции TTL[^6] в определении таблицы, вы сможете расширить объем доступного дискового пространства для кластера ClickHouse объектным хранилищем, причем по более низкой цене, чем стандартные диски.

# Работа с данными Метрики при помощи Yandex Query

Yandex Query (YQ) - это serverless-движок для работы с данными, находящимися во внешнем объектном хранилище или во внешней БД (на декабрь 2023 поддерживаются PostgreSQL и ClickHouse[^7] и PostgreSQL[^8]), в том числе с возможностью выполнения федеративных запросов над данными из разных источников.

При помощи YQ можно выполнять как аналитическую обработку данных, так и потоковую обработку данных (из Yandex Data Streams (YDS)).

YQ расширяет возможности аналитической обработки данных и дополняет ClickHouse при помощи следующих свойств:
- Хранение данных в Object Storage
- Оплата только за потребление ресурсов во время выполнения запросов
- YQL — SQL-подобный язык запросов
- Web UI со встроенным учебником
- Поддержка Yandex Query как источника для Datalens[^7]

Ниже мы рассмотрим простой сценарий обогащения данных Метрики из ClickHouse с сохранением результата запроса в файл в Object Storage. 

## Чтение данных источника в Yandex Query
При обращении к данным через Yandex Query необходимо описать схему колонок и типов. Сделать это можно как напрямую в YQL запросе при помощи конструкции `WITH .. SCHEMA (..)` [^10], так посредством механизма привязки (binding).

Для демонстрации работы Yandex Query с объектным хранилищем создадим соединение[^11], которое понадобится нам в дальнейшем, и привязку[^12] к каталогу с файлами ранее выгруженной из ClickHouse таблицы хитов:
![yq-object-storage](img/yq-object-storage.png?raw=true "Подключение к Object Storage из Yandex Query")

![yq-s3-binding-1](img/yq-s3-binding-1.png?raw=true "Привязка к объектам S3 - 1")

(в таблице большое количество колонок, для демонстрации зададим не все)
![yq-s3-binding-2](img/yq-s3-binding-2.png?raw=true "Привязка к объектам S3 - 2")

```sql
SELECT
    `CounterID`,
    `EventDate`,
    `CounterUserIDHash`,
    `UTCEventTime`,
    `WatchID`,
    `AdvEngineID`,
    `AdvEngineStrID`,
    `BrowserCountry`,
    `BrowserEngineID`,
    `BrowserEngineStrID`,
    `BrowserEngineVersion1`,
    `URL`
FROM `metrica-hits-s3`
LIMIT 10;
```
![yq-s3-binding-select](img/yq-s3-binding-select.png?raw=true "Выборка из привязки")

Выполним аналогичный запрос без привязки - напрямую из соединения с заданием схемы прямо в запросе:
```sql
SELECT
    `CounterID`,
    `EventDate`,
    `CounterUserIDHash`,
    `UTCEventTime`,
    `WatchID`,
    `AdvEngineID`,
    `AdvEngineStrID`,
    `BrowserCountry`,
    `BrowserEngineID`,
    `BrowserEngineStrID`,
    `BrowserEngineVersion1`,
    `URL`
FROM `<id подключения к Object Storage>`.`/metrica/hits/hits*.csv.gz`
    WITH
    (
        format = csv_with_names,
        compression = gzip,
        Schema =
        (
            CounterID UInt32 Not null, 
            EventDate date not null,
            CounterUserIDHash uint64 not null,
            UTCEventTime datetime not null,
            WatchID uint64,
            AdvEngineID uint16,
            AdvEngineStrID string,
            BrowserCountry string, 
            BrowserEngineID uint16,
            BrowserEngineStrID string,
            BrowserEngineVersion1 uint16,
            URL string
        )
    ) 
LIMIT 10;
```
![yq-select-with-schema](img/yq-select-with-schema.png?raw=true "Yandex Query - Выборка данных напрямую из соединения")

Теперь создадим соединение к Managed ClickHouse:
![yq-clickhouse](img/yq-clickhouse.png?raw=true "Подключение к ClickHouse из Yandex Query")


```sql
/* Выполним проверочный запрос к таблице хитов */
    select * from metrica.`hits_<id трансфера>`
    limit 10;
```
![yq-clickhouse-select](img/yq-clickhouse-select.png?raw=true "Запрос к таблице ClickHouse из Yandex Query")

Загрузим следующий версионный справочник в виде CSV-файла в объектное хранилище и создадим привязку:

```csv
"BrowserCountry","BrowserCountryDesc","FromDT","ToDT"
"ru","Russian Federation","2023-01-01","2023-11-01"
"ru","Russian Empire","2023-01-02","9999-12-31"
```
![yq-s3-dim-table](img/yq-s3-dim-table.png?raw=true "Привязка S3-файла в Yandex Query")

Сохраним в CSV-файл результат федеративной выборки, в которой соединяются таблица фактов из ClickHouse с загруженным в объектное хранилище справочником:
```sql
/* Вставка в файл выборки федеративным запросом */
insert into `<имя привязки>`.`/metrica/yq/`
    WITH
    (
        format='csv_with_names'
    )
SELECT
    f.`BrowserCountry`,
    f.`EventDate`,
    d.`BrowserCountryDesc`,
    count(1) as cnt
FROM `metrica-hits-s3` f
join   `dim_browser_country` d
on f.`BrowserCountry` == d.`BrowserCountry`
where f.`BrowserCountry`='ru'
and f.`EventDate` >= d.`FromDT` and f.`EventDate` <= d.`ToDT`
group by
    f.`BrowserCountry`,
    f.`EventDate`,
    d.`BrowserCountryDesc`
order by f.`EventDate`
```

![yq-s3-insert-1](img/yq-s3-insert-1.png?raw=true "Вставка данных в файл через YQ")
![yq-s3-insert-2](img/yq-s3-insert-2.png?raw=true "Созданный через YQ файл с данными в S3")
![yq-s3-insert-3](img/yq-s3-insert-3.png?raw=true "Данные файла из S3")

Помимо записи через соединение, возможна также запись данных через привязку[^13].

## Визуализация данных из Yandex Object Storage в Yandex DataLens

Datalens поддерживает Yandex Query как источник[^9]. Т.о. мы можем создавать визуализации на основе данных из Object Storage, а также данных из федеративных запросов к нескольким источникам, используя движок YQ для их выполнения.

![datalens-yq](img/datalens-yq.png?raw=true "Подключение к YQ из Datalens")
![datalens-yq-dataset](img/datalens-yq-dataset.png?raw=true "Датасет из YQ в Datalens")
![datalens-yq-chart](img/datalens-yq-chart.png?raw=true "Чарт на основе данных из YQ в Datalens")

# Заключение
Ваши предложения по модификации сценария вы можете направить через pull request.

Для вопросов, пожеланий и консультаций по сервисам платформы данных Yandex Cloud: группа https://t.me/YandexDataPlatform в Telegram

***
***
[^1]: https://yandex.ru/support/metrica/pro/cloud.html
[^2]: https://yandex.ru/support/metrica/pro/data-work.html
[^3]: https://cloud.yandex.ru/docs/tutorials/dataplatform/metrika-to-clickhouse
[^4]: https://cloud.yandex.ru/docs/managed-clickhouse
[^5]: https://cloud.yandex.ru/docs/managed-clickhouse/operations/s3-access
[^6]: https://cloud.yandex.ru/blog/posts/2022/11/clickhouse-kazanexpress
[^7]: https://cloud.yandex.ru/docs/query/sources-and-sinks/clickhouse
[^8]: https://cloud.yandex.ru/docs/query/sources-and-sinks/postgresql
[^9]: https://cloud.yandex.ru/docs/query/tutorials/datalens
[^10]: https://cloud.yandex.ru/docs/query/sources-and-sinks/formats#primer-chteniya-dannyh
[^11]: https://cloud.yandex.ru/docs/query/operations/connection
[^12]: https://cloud.yandex.ru/docs/query/operations/binding
[^13]: https://cloud.yandex.ru/docs/query/sources-and-sinks/object-storage-write#bindings-write