# AcumaticaCycleCountPlanner
SQL View to utilize for Cycle Count Planning and secondary for ABC planning
# Cycle Count Planning & ABC Classification


*Prepared by Nicole Ronchetti — March 2026*

---

## Overview

This document explains the two reporting views built into your Acumatica system to support cycle count planning. These views are accessed through Generic Inquiries (GIs) and provide the data your warehouse team needs to decide what to count, when to count it, and how often.

**Cycle Count Planner** — Shows every item at every warehouse with current stock levels, transaction activity, last count dates, and a priority score that ranks items by how urgently they need counting.

**ABC Classification** — Ranks items within each warehouse by their dollar value (on-hand quantity × unit cost) and assigns an A, B, or C class. This drives recommended count frequencies.

---

## Cycle Count Planner

This view returns one row per item per warehouse. It only includes active stock items that have a presence in at least one warehouse. Items that have never been stocked anywhere are excluded.

### Key Columns

**Qty On Hand / Qty Available** — Current stock position at this warehouse. Quantity Available excludes allocated and in-transit stock.

**Unit Cost / Extended Value** — The weighted average cost per unit derived from Acumatica's internal cost layers, and the total dollar value of on-hand inventory (Qty On Hand × Unit Cost).

**Txns (90d) / Units Moved (90d)** — The number of distinct inventory transactions and total units moved (receipts, issues, adjustments, transfers) in the last 90 days. These measure how active the item is.

**Last Transaction Date / Last Count Date** — When the item last moved and when it was last physically counted at this warehouse.

**Last Count Variance** — The difference between the book quantity and the physical quantity at the most recent completed physical count.

### Velocity Categories

Each item is classified into a velocity category based on its recent transaction activity. This helps your team focus counting efforts on items that move frequently, where discrepancies are most likely to occur.

| Category | Criteria |
|---|---|
| **High Velocity** | 20 or more transactions in the last 90 days |
| **Medium Velocity** | 5 to 19 transactions in the last 90 days |
| **Low Velocity** | 1 to 4 transactions in the last 90 days, or has stock on hand |
| **Inactive** | Zero stock on hand and zero transactions in the last 90 days |

### Count Priority Score

Every item receives a priority score from 0 to 100. Higher scores mean the item should be counted sooner. The score is the sum of three components, each reflecting a different reason an item might need counting.

#### Value Component (0–40 points)

| Extended Value | Points |
|---|---|
| $5,000+ | 40 |
| $1,000 – $4,999 | 30 |
| $250 – $999 | 20 |
| $1 – $249 | 10 |
| $0 (no stock or no cost) | 0 |

#### Velocity Component (0–30 points)

| Transaction Activity (90 days) | Points |
|---|---|
| 20+ transactions | 30 |
| 10 – 19 transactions | 22 |
| 5 – 9 transactions | 15 |
| 1 – 4 transactions | 8 |
| No transactions | 0 |

#### Count Staleness Component (0–30 points)

| Time Since Last Count | Points |
|---|---|
| Never counted or 180+ days | 30 |
| 91 – 180 days | 22 |
| 46 – 90 days | 15 |
| 15 – 45 days | 8 |
| Counted within 14 days | 0 |

**How to read the score:** A score of 100 means the item is high-value, high-velocity, and hasn't been counted in over 6 months — it should be at the top of your count list. A score of 30 means only one factor is flagged (for example, never counted but no stock and no activity). Sort the GI by Priority Score descending to generate your count worksheets.

> **Example:** An item with $3,000 in extended value (30 pts), 12 transactions in the last 90 days (22 pts), and last counted 100 days ago (22 pts) scores **74 out of 100**.

---

## ABC Classification

The ABC Classification view ranks every stocked item within each warehouse by its extended dollar value and assigns it to one of three classes. This follows the standard inventory management principle that a small percentage of items typically account for most of the inventory value.

### How It Works

Items within each warehouse are sorted by extended value from highest to lowest. A running cumulative percentage is calculated. Each item is assigned a class based on where it falls in that cumulative distribution:

| Class | Share of Total Value | Count Frequency | Counts Per Year |
|---|---|---|---|
| **A** | Top 80% of warehouse value | Monthly | 12 |
| **B** | Next 15% (80–95%) | Quarterly | 4 |
| **C** | Remaining 5% | Semi-Annually | 2 |

> **Example:** If a warehouse holds $500,000 in total inventory value, the items that collectively make up the first $400,000 (top 80%) are Class A. The next $75,000 (80–95%) are Class B. The remaining $25,000 are Class C.

### Recommended Count Frequencies

Each ABC class comes with a recommended count frequency. Class A items should be counted monthly because they represent the majority of your inventory investment — a discrepancy on a high-value item has a larger financial impact. Class B items are counted quarterly, and Class C items semi-annually.

These are recommendations, not rules. Your team may adjust based on operational factors like theft risk, supplier reliability, or items with a history of count variances.

### Additional Columns

**Value Rank** — The item's position when sorted by extended value within its warehouse (1 = highest value item).

**% of Total Value** — What percentage of the warehouse's total inventory value this single item represents.

**Cumulative % of Value** — The running total percentage. When this crosses 80%, you've reached the boundary between Class A and Class B.

---

## Using These Reports Together

The Cycle Count Planner and ABC Classification serve complementary purposes. The ABC Classification tells you how often each item should ideally be counted. The Cycle Count Planner tells you which specific items need counting right now, ranked by urgency.

**A practical workflow:** Use the ABC Classification to set your overall counting schedule (all A items monthly, B items quarterly, C items twice a year). Then each week, pull up the Cycle Count Planner sorted by Priority Score to generate that week's count list. Items that are overdue based on their ABC frequency will naturally rise to the top of the priority list because the staleness component of their score increases over time.

---

*Junova Consulting — We don't sell software. We build freedom.*
