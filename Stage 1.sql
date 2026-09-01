-- step 1

create database if not exists supply_chain_analytics;
use supply_chain_analytics;

drop table if exists orders_raw;

create table orders_raw (
    type varchar(20),
    days_for_shipping_real int,
    days_for_shipment_scheduled int,
    benefit_per_order decimal(10,2),
    sales_per_customer decimal(10,2),
    delivery_status varchar(50),
    late_delivery_risk tinyint,
    category_id int,
    category_name varchar(100),
    customer_city varchar(100),
    customer_country varchar(100),
    customer_email varchar(100),
    customer_fname varchar(100),
    customer_id int,
    customer_lname varchar(100),
    customer_password varchar(100),
    customer_segment varchar(50),
    customer_state varchar(50),
    customer_street varchar(150),
    customer_zipcode varchar(20),
    department_id int,
    department_name varchar(100),
    latitude decimal(10,6),
    longitude decimal(10,6),
    market varchar(50),
    order_city varchar(100),
    order_country varchar(100),
    order_customer_id int,
    order_date datetime,
    order_id int,
    order_item_cardprod_id int,
    order_item_discount decimal(10,2),
    order_item_discount_rate decimal(6,4),
    order_item_id int,
    order_item_product_price decimal(10,2),
    order_item_profit_ratio decimal(6,4),
    order_item_quantity int,
    sales decimal(10,2),
    order_item_total decimal(10,2),
    order_profit_per_order decimal(10,2),
    order_region varchar(50),
    order_state varchar(100),
    order_status varchar(50),
    order_zipcode varchar(20),
    product_card_id int,
    product_category_id int,
    product_description text,
    product_image text,
    product_name varchar(150),
    product_price decimal(10,2),
    product_status tinyint,
    shipping_date datetime,
    shipping_mode varchar(50)
);

load data local infile '/path/to/DataCoSupplyChainDataset.csv'
into table orders_raw
character set latin1
fields terminated by ',' optionally enclosed by '"'
lines terminated by '\n'
ignore 1 rows
(type, days_for_shipping_real, days_for_shipment_scheduled, benefit_per_order,
 sales_per_customer, delivery_status, late_delivery_risk, category_id, category_name,
 customer_city, customer_country, customer_email, customer_fname, customer_id,
 customer_lname, customer_password, customer_segment, customer_state, customer_street,
 customer_zipcode, department_id, department_name, latitude, longitude, market,
 order_city, order_country, order_customer_id, @order_date, order_id,
 order_item_cardprod_id, order_item_discount, order_item_discount_rate, order_item_id,
 order_item_product_price, order_item_profit_ratio, order_item_quantity, sales,
 order_item_total, order_profit_per_order, order_region, order_state, order_status,
 order_zipcode, product_card_id, product_category_id, product_description,
 product_image, product_name, product_price, product_status, @shipping_date, shipping_mode)
set
    order_date = coalesce(
        str_to_date(@order_date, '%c/%e/%Y %H:%i'),
        str_to_date(@order_date, '%c-%e-%y %H:%i')
    ),
    shipping_date = coalesce(
        str_to_date(@shipping_date, '%c/%e/%Y %H:%i'),
        str_to_date(@shipping_date, '%c-%e-%y %H:%i')
    );

select count(*) as row_count,
       sum(order_date is null or shipping_date is null) as bad_dates,
       count(distinct product_card_id) as sku_count
from orders_raw;

show warnings limit 20;


create or replace view orders_clean as
select *
from orders_raw
where order_status not in ('CANCELED', 'SUSPECTED_FRAUD');

select count(*) as rows_after_cleaning from orders_clean;


-- step 2

drop table if exists calendar_months;

create table calendar_months as
with recursive months as (
    select date_format(min(order_date), '%Y-%m-01') as demand_month
    from orders_clean
    union all
    select date_add(demand_month, interval 1 month)
    from months
    where demand_month < (select date_format(max(order_date), '%Y-%m-01') from orders_clean)
)
select demand_month from months;

select count(*) from calendar_months;

drop table if exists monthly_demand;

create table monthly_demand as
select
    sku.product_card_id,
    cal.demand_month,
    coalesce(sum(oc.order_item_quantity), 0) as monthly_qty
from (select distinct product_card_id from orders_clean) sku
cross join calendar_months cal
left join orders_clean oc
    on oc.product_card_id = sku.product_card_id
   and date_format(oc.order_date, '%Y-%m-01') = cal.demand_month
group by sku.product_card_id, cal.demand_month;

select count(*) from monthly_demand;


-- step 3

drop table if exists demand_stats;

create table demand_stats as
select
    product_card_id,
    avg(monthly_qty) as avg_demand,
    stddev_samp(monthly_qty) as stddev_demand
from monthly_demand
group by product_card_id;

drop table if exists leadtime_stats;

create table leadtime_stats as
select
    product_card_id,
    avg(days_for_shipping_real) as avg_leadtime,
    stddev_samp(days_for_shipping_real) as stddev_leadtime
from orders_clean
group by product_card_id;

select count(*) from demand_stats;
select count(*) from leadtime_stats;


-- step 4

drop table if exists abc_class;

create table abc_class as
with revenue_by_sku as (
    select product_card_id, sum(sales) as total_revenue
    from orders_clean
    group by product_card_id
),
ranked as (
    select
        product_card_id,
        total_revenue,
        sum(total_revenue) over (order by total_revenue desc)
            / sum(total_revenue) over () as cum_revenue_pct
    from revenue_by_sku
)
select
    product_card_id,
    total_revenue,
    round(cum_revenue_pct * 100, 2) as cum_revenue_pct,
    case
        when cum_revenue_pct <= 0.80 then 'A'
        when cum_revenue_pct <= 0.95 then 'B'
        else 'C'
    end as abc_class
from ranked;

select abc_class, count(*) from abc_class group by abc_class;


-- step 5

drop table if exists xyz_class;

create table xyz_class as
select
    product_card_id,
    avg_demand,
    stddev_demand,
    round(stddev_demand / nullif(avg_demand, 0), 3) as cv,
    case
        when stddev_demand / nullif(avg_demand, 0) < 0.2 then 'X'
        when stddev_demand / nullif(avg_demand, 0) <= 0.5 then 'Y'
        else 'Z'
    end as xyz_class
from demand_stats;

select xyz_class, count(*) from xyz_class group by xyz_class;


-- step 6

drop table if exists sku_master;

create table sku_master as
select
    d.product_card_id,
    d.avg_demand,
    d.stddev_demand,
    l.avg_leadtime,
    l.stddev_leadtime,
    a.total_revenue,
    a.abc_class,
    x.cv,
    x.xyz_class,
    concat(a.abc_class, x.xyz_class) as abc_xyz_segment
from demand_stats d
join leadtime_stats l on d.product_card_id = l.product_card_id
join abc_class a on d.product_card_id = a.product_card_id
join xyz_class x on d.product_card_id = x.product_card_id
order by a.total_revenue desc;

select count(*) from sku_master;


-- step 7

select * from sku_master;

select product_card_id, demand_month, monthly_qty
from monthly_demand
order by product_card_id, demand_month;

-- select product_card_id, demand_month, monthly_qty
-- from monthly_demand
-- order by product_card_id, demand_month
-- into outfile 'monthly_demand_export.csv'
-- fields terminated by ',' optionally enclosed by '"'
-- lines terminated by '\n';
