# TerraPulse SQL Project

**Multi-Source Market Intelligence & Data Warehouse Pipeline** for TerraPulse
Global Ltd., a fictional clean-tech manufacturer (solar, EV charging, smart
grid IoT, home climate tech, industrial efficiency hardware). Built as a
one-week SQL capstone: five disconnected raw feeds are ingested, cleaned,
and normalized into a governed relational warehouse, then queried for
executive-level business intelligence.

## Project overview

- **Problem:** commercial data spread across 5 raw sources (500K marketplace
  orders, 500K logistics records, 15K customer profiles, a 200-row supplier
  catalog, and 8 FX rates) with inconsistent casing, 4 different date
  formats, 8 transacting currencies, and missing/dirty fields.
- **Solution:** a two-tier MySQL warehouse — permissive `stg_*` staging
  tables feed fully typed, key-constrained `dim_*` / `fct_*` production
  tables — plus a reporting view layer for dashboards.
- **Output:** 8 business intelligence queries covering revenue and
  profitability, geographic and currency exposure, carrier SLA performance,
  customer segmentation, dormant customers, and dead stock.

## Tech stack

- MySQL 8.0+
- MySQL Workbench (import wizard, ERD reverse engineering)
- dbdiagram.io (ERD source of truth — see `diagrams/`)

## Repository structure

```
terrapulse-sql-project/
├── README.md                    Project overview and setup instructions
├── schema/
│   └── terrapulse_ddl.sql       Full DDL: CREATE DATABASE to CREATE VIEW
├── etl/
│   └── cleaning_pipeline.sql    All ETL transformation queries
├── analytics/
│   └── business_queries.sql     All Phase 4 intelligence queries + Phase 5 transaction demo
├── diagrams/
│   └── terrapulse_erd.dbml      ERD source (import at dbdiagram.io to export PNG)
└── screenshots/
    └── (at least 6 screenshots of query results)
```

## Setup guide

1. Create a MySQL 8.0+ instance (local or Workbench-connected).
2. Run `schema/terrapulse_ddl.sql` — builds `terrapulse_dw` from scratch,
   including staging tables, production tables, constraints, and views.
3. Load the 5 raw source files into their matching `stg_*` tables via the
   MySQL Workbench **Table Data Import Wizard** (CSV/TSV), or `JSON_TABLE()`
   for the JSON sources — see the comment block at the top of
   `etl/cleaning_pipeline.sql`.
4. Run `etl/cleaning_pipeline.sql` — verifies ingestion counts, audits data
   quality, and transforms staging data into the production tables.
5. Run `analytics/business_queries.sql` — executes all 8 BI queries and the
   Phase 5 transaction/savepoint/rollback demonstration.

## Data warehouse schema

See `diagrams/terrapulse_erd.dbml`. Summary: 4 dimension tables
(`dim_customers`, `dim_products`, `dim_categories`, `dim_currencies`) feed
`fct_orders`, which has a 1-to-1 relationship with `fct_logistics`.

## Team

RUTH OKON THOMPSON

## License

Educational capstone project — Veracity+ SQL Program.
