# Integrating Metrica Pro data into Yandex Cloud

The solution below explains how to integrate and work with Metrica data in Yandex Cloud. This guide uses resources from both Yandex Metrica[^1],[^2] and Yandex Cloud[^3] websites.

> [!IMPORTANT]
> To transfer data from Yandex Metrica, you need to activate [Metrica Pro](https://yandex.ru/support/metrica/pro/intro.html).

## Release notes

- Initial release (v01) as of 05/12/2023

## How it works

### How to work with Metrica Pro data in Yandex Cloud

![metrica-pro-yc](img/metrica-pro-yc.png?raw=true "How to work with Metrica Pro data in Yandex Cloud")

### Services to use

1. [Yandex Data Transfer](https://yandex.cloud/en/services/data-transfer) for delivering Metrica data to a cloud
1. [Managed Service for ClickHouse](https://yandex.cloud/en/services/managed-clickhouse) as a buffer zone and data source for DataLens
1. [Yandex DataLens](https://yandex.cloud/en/services/datalens) for visualizing data
1. [Yandex Object Storage](https://yandex.cloud/en/services/storage) for storing data in file format
1. [Yandex Query](https://yandex.cloud/en/services/query) for ad-hoc analysis using SQL queries

### Steps to create a solution

1. Setting up the infrastructure
    1. Preparing a ClickHouse cluster
    1. Configuring Metrica and ClickHouse connection endpoints
    1. Configuring and activating the transfer
1. Visualizing Metrica data in DataLens
1. Exporting data to Yandex Object Storage (S3)
1. Managing Metrica data using Yandex Query

# Setting up the infrastructure

To quickly set up the infrastructure, use the scripts from the [`terraform`](/terraform) folder. The Terraform scripts cover all components, except for the Metrica endpoint and the transfer itself, which were not yet supported by the provider at the time of this writing (December 2023). You will need to create these through the web UI.

## Creating a ClickHouse cluster

If you do not have a ClickHouse cluster, create one in your cloud using the Terraform script, YC CLI, or Yandex Cloud UI console. For detailed info on working with ClickHouse clusters, see the Managed Service for ClickHouse[^4] page. 

## Configuring Metrica and ClickHouse connection endpoints

Create Metrica source connection endpoints:

![metrica-source](img/metrica-source.png?raw=true "Creating a Metrica connection endpoint")

Create ClickHouse source and target connection endpoints:

![clickhouse-target](img/clickhouse-target.png?raw=true "Creating a ClickHouse connection endpoint")

A Metrica source delivers two tables: `visits` and `hits`.
Note that if there are no tables in the target, Data Transfer will automatically create them based on the target sharding settings. To change the table topology, deactivate the transfer once it is created and modify the table structure. In the endpoint properties, set the cleanup policy to either `Truncate` or `Do not clean up`. To view the definition (DDL) examples for the `visits` and `hits` tables, see the [`ddl`](/ddl) folder.

Metrica transfers run in replication mode, so you may want to select `Do not clean up`. This way, if you deactivate the transfer for any reason, the data from the prior run will be retained when you re-activate it.

## Configuring and activating the transfer

Create a transfer:

![transfer-create](img/transfer-create.png?raw=true "Creating a transfer")

Next, activate it and check the target for the transferred data:

![clickhouse-hits-select](img/clickhouse-hits-select.png?raw=true "`hits` table data")

Note that Data Transfer adds the transfer ID to the names of tables when creating them.

# Visualizing Metrica data in DataLens

Let’s use the typical data queries outlined on the Metrica[^2] website as an example.
First, create a ClickHouse cluster connection and then proceed to creating QL charts.

## Traffic chart

```sql
/*
https://yandex.ru/support/metrica/pro/data-work.html#data-work__traffic

- Make sure to specify the valid table name in your database.
- Remove counter ID as needed.
- In the **Parameters** tab, create a parameter named `interval` and assign it the `date-interval` type.
*/ 

SELECT StartDate AS `ym:s:date`, 
        sum(Sign) AS `ym:s:visits` -- Properly collapsing multiple visit versions into a single, most up-to-date record while calculating the total number of visits
from 
metrica_copy.visits_<transfer_ID>
as `default.visits_all` 
WHERE `ym:s:date` >= {{interval_from}} -- Historical data prior to the connector setup in this version is not supported.
        and `ym:s:date` <= {{interval_to}} -- Today's data, as well as delayed updates for subsequent days, such as offline conversions, may be displayed in the interface with a lag.
GROUP BY `ym:s:date` 
WITH TOTALS  
HAVING `ym:s:visits` >= 0.0 
ORDER BY `ym:s:date` ASC 
limit 0,10
```

![datalens-chart-visits](img/datalens-chart-visits.png?raw=true "Traffic chart")

## Traffic source chart

```sql
/*
https://yandex.ru/support/metrica/pro/data-work.html#data-work__utm

- Make sure to specify the valid table name in your database.
- Remove counter ID as needed.
- In the **Parameters** tab, create a parameter named `interval` and assign it the `date-interval` type.
*/ 

SELECT
    `TrafficSource.UTMSource`[indexOf(`TrafficSource.Model`, 2)] AS `ym:s:lastSignUTMSource`,
    sum(Sign) AS `ym:s:visits`,
    least(uniqExact(CounterUserIDHash), `ym:s:visits`) AS `ym:s:users`,
    100. * (sum(IsBounce * Sign) / `ym:s:visits`) AS `ym:s:bounceRate`,
    sum(PageViews * Sign) / `ym:s:visits` AS `ym:s:pageDepth`,
    sum(Duration * Sign) / `ym:s:visits` AS `ym:s:avgVisitDurationSeconds`,
    sumArray(arrayMap(x -> (if(isFinite(x), x, 0) * Sign), arrayMap(x_0 -> toInt64(notEmpty(x_0)), `EPurchase.ID`))) AS `ym:s:ecommercePurchases`
FROM metrica_copy.visits_<transfer_ID>  -- Provide your database and your `visits` table here.
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

![datalens-chart-utmsources](img/datalens-chart-utmsources.png?raw=true "Traffic source chart")

## Dashboards

Add charts to the dashboard and set the `interval` parameter (on the **Manual input** tab, select the **Calendar** type and check the **Interval** box):

![datalens-dashboard](img/datalens-dashboard.png?raw=true "Metrica dashboard")

# Exporting data to Yandex Object Storage

To enable data export to Yandex Object Storage, configure access from the ClickHouse[^5] cluster.

Once access is configured, you will be able to export data to your object storage using the built-in S3 table engine in ClickHouse.

```sql
/* Creating an S3 table while replacing the cluster ID, transfer ID, and S3 bucket name with your own values */

create table metrica.hits_s3 on cluster <cluster_ID> as hits_<transfer_ID>
ENGINE = S3('https://storage.yandexcloud.net/<S3_bucket_name>/metrica/hits/hits.csv.gz',
 'CSVWithNames', 'gzip')
SETTINGS input_format_with_names_use_header = 1;


/* Inserting data into the S3 table */
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<transfer_ID> where EventDate=cast('2023-11-01' as date);
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<transfer_ID> where EventDate=cast('2023-11-02' as date);
insert into hits_s3 settings s3_create_new_file_on_insert=1 select * from hits_<transfer_ID> where EventDate=cast('2023-11-03' as date);

/* Checking the paths of the exported files */
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-01' as date) limit 1
union all
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-02' as date) limit 1
union all
select _path, _file, EventDate from hits_s3 where EventDate=cast('2023-11-03' as date) limit 1
```

![clickhouse-s3-table](img/clickhouse-s3-table.png?raw=true "S3 table")

```sql
/* Comparing the source table with the S3 table */
select 's3' as storage, count(1) as cnt from hits_s3
union all 
select 'ch' as storage, count(1) as cnt from hits_<transfer_ID> where EventDate between cast('2023-11-01' as date) and cast('2023-11-03' as date);

storage|cnt    |
-------+-------+
ch     |3902732|
s3     |3902732|
```
> [!IMPORTANT]
> Exporting large chunks of data to Yandex Object Storage may result in a timeout error. To prevent this, increase the `socket_timeout` parameter value or break the data to export into smaller chunks using multiple queries with the `WHERE` filter.

In addition to explicitly exporting data to Object Storage for subsequent data management using other tools, Yandex Cloud supports hybrid storage mode for Managed Service for ClickHouse. By setting up automatic data transfer to hybrid storage using TTL[^6] in the table definition, you will be able to expand the available disk space for your ClickHouse cluster with Object Storage, which is more cost-effective than using regular disks.

# Managing Metrica data using Yandex Query

Yandex Query, or YQ, is a serverless engine for managing data in an external object storage or external DB (ClickHouse[^7] and PostgreSQL[^8] are supported as of December 2023), enabling federated data queries across multiple sources.

With YQ, you can perform both analytical and stream data processing (from Yandex Data Streams, or YDS).

Yandex Query extends analytical data processing features and enhances ClickHouse with the following options:
- Storing data in Object Storage.
- Paying only for the resources consumed while running queries.
- Web UI with an integrated guide.
- Support for Yandex Query as a source for Datalens[^7].

Below, you can find a simple example of how to enrich Metrica data from ClickHouse and save the query result to a file in Object Storage. 

## Reading data from a Yandex Query source

When accessing data via Yandex Query, you need to define the column schema and types. You can do this by using either the `WITH .. SCHEMA (..)` construct[^10] directly in your SQL query or the binding feature.

To demonstrate how Yandex Query works with Object Storage, we will create a connection[^11] for later use and a binding[^12] to the folder containing the files previously exported from the ClickHouse `hits` table:
![yq-object-storage](img/yq-object-storage.png?raw=true "Connecting to Object Storage from Yandex Query")

![yq-s3-binding-1](img/yq-s3-binding-1.png?raw=true "Binding 1 to S3 objects")

(This table features many columns, but we will limit the demonstration to just a few.)
![yq-s3-binding-2](img/yq-s3-binding-2.png?raw=true "Binding 2 to S3 objects")

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
![yq-s3-binding-select](img/yq-s3-binding-select.png?raw=true "Selecting data from the binding")

Run a similar query without binding, selecting data directly from the connection by defining the schema in the query:
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
FROM `<Object_Storage_connection_ID>`.`/metrica/hits/hits*.csv.gz`
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
![yq-select-with-schema](img/yq-select-with-schema.png?raw=true "Yandex Query: selecting data directly from the connection")

Next, create a connection to Managed Service for ClickHouse:
![yq-clickhouse](img/yq-clickhouse.png?raw=true "Connecting to ClickHouse from Yandex Query")


```sql
/* Running a test query to the `hits` table */
    select * from metrica.`hits_<transfer_ID>`
    limit 10;
```
![yq-clickhouse-select](img/yq-clickhouse-select.png?raw=true "Querying the ClickHouse table from Yandex Query")

Upload the following versioned reference as a CSV file to the object storage and create a binding:

```csv
"BrowserCountry","BrowserCountryDesc","FromDT","ToDT"
"ru","Russian Fed.","2023-01-01","2023-11-01"
"ru","Russian Federation","2023-01-02","2099-12-31"
```
![yq-s3-dim-table](img/yq-s3-dim-table.png?raw=true "S3 file binding in Yandex Query")

Save the result of the federated query, which joins the ClickHouse fact table with the reference uploaded to the object storage, into a CSV file:
```sql
/* Inserting the federated query result into a file */
insert into `<binding_name>`.`/metrica/yq/`
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

![yq-s3-insert-1](img/yq-s3-insert-1.png?raw=true "Inserting data into a file via Yandex Query")
![yq-s3-insert-2](img/yq-s3-insert-2.png?raw=true "Data file created using Yandex Query in S3 storage")
![yq-s3-insert-3](img/yq-s3-insert-3.png?raw=true "File data from S3 storage")

Apart from connections, you can also use bindings[^13] to write data.

## Visualizing data from Yandex Object Storage in DataLens

DataLens supports Yandex Query as a source[^9], enabling visualization based on data from Object Storage and federated queries across multiple sources using the Yandex Query engine.

![datalens-yq](img/datalens-yq.png?raw=true "Connecting to Yandex Query from DataLens")
![datalens-yq-dataset](img/datalens-yq-dataset.png?raw=true "Dataset from Yandex Query in DataLens")
![datalens-yq-chart](img/datalens-yq-chart.png?raw=true "Chart based on Yandex Query data in DataLens")

# Conclusion

You can submit your suggestions for modifying the scenario through a pull request.

For questions, suggestions, and advice on Yandex Cloud services, [join our Telegram chat](https://t.me/YandexDataPlatform).

[^1]: https://yandex.ru/support/metrica/pro/cloud.html
[^2]: https://yandex.ru/support/metrica/pro/data-work.html
[^3]: https://yandex.cloud/en/docs/tutorials/dataplatform/metrika-to-clickhouse
[^4]: https://yandex.cloud/en/docs/managed-clickhouse
[^5]: https://yandex.cloud/en/docs/managed-clickhouse/operations/s3-access
[^6]: https://yandex.cloud/en/blog/posts/2022/11/clickhouse-kazanexpress
[^7]: https://yandex.cloud/en/docs/query/sources-and-sinks/clickhouse
[^8]: https://yandex.cloud/en/docs/query/sources-and-sinks/postgresql
[^9]: https://yandex.cloud/en/docs/query/tutorials/datalens
[^10]: https://yandex.cloud/en/docs/query/sources-and-sinks/formats#primer-chteniya-dannyh
[^11]: https://yandex.cloud/en/docs/query/operations/connection
[^12]: https://yandex.cloud/en/docs/query/operations/binding
[^13]: https://yandex.cloud/en/docs/query/sources-and-sinks/object-storage-write#bindings-write
