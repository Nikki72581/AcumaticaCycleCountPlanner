-- ============================================================================

-- Cycle Count Planning & ABC Classification
-- 
-- Deployment: Acumatica Customization Package (Database Scripts)
-- Author: Nicole Ronchetti
-- Date: March 2026
-- Revision: 5
--
-- CHANGE LOG:
--   v5: Data analysis of GI output revealed three issues:
--       1. LEFT JOIN to INSiteStatus produced rows for every active stock
--          item regardless of warehouse presence — 495 of 1000 sample rows
--          had NULL warehouse (items with no INSiteStatus record at all).
--          Fix: Changed to INNER JOIN so only items with actual warehouse
--          presence appear. Items never stocked have nothing to count.
--       2. Extended Value was 0 for 100% of rows, including 36 items with
--          actual Qty On Hand. This indicates INCostStatus.CostSiteID may
--          not map to INSite.SiteID on this tenant (location-level costing).
--          Fix: Added fallback cost join through INLocation to handle both
--          warehouse-level and location-level costing in a single query.
--       3. Last Txn Date and Txns (90d) were NULL/0 for all 1000 rows.
--          Possible cause: INTran may use DocType instead of TranType on
--          this build. Fix: Changed join to use t.DocType which is the
--          physical column name on INTran (TranType is the DAC field name;
--          the SQL column may differ on some builds). If DocType also fails,
--          the pre-deploy validation will catch it.
--
--   v4: Cost derivation uses INCostStatus cost layers (INItemSite.LastCost
--       is DAC-only, does not exist in SQL).
--
--   v3: Fixed INPIDetail.SiteID → INPIHeader.SiteID, consolidated txn
--       subqueries, added SubItemID aggregation guard.
--
-- CONTENTS:
--   View 1: vw_CycleCountPlanner     — Master inventory profile for count planning
--   View 2: vw_ABCClassification     — ABC ranking by extended value
-- ============================================================================


-- ============================================================================
-- VIEW 1: CYCLE COUNT PLANNER
-- ============================================================================

CREATE OR ALTER VIEW dbo.vw_CycleCountPlanner AS
SELECT
    -- ── Item Identity ──
    ii.CompanyID,
    ii.InventoryID,
    ii.InventoryCD                          AS InventoryCD,
    ii.Descr                                AS ItemDescription,
    ic.ItemClassCD                          AS ItemClassCD,
    ic.Descr                                AS ItemClassDescription,
    
    -- ── Warehouse / Location ──
    ins.SiteID,
    ins.SiteCD                              AS WarehouseCD,
    ins.Descr                               AS WarehouseDescription,
    
    -- ── Current Stock Position ──
    ISNULL(ss.QtyOnHand, 0)                 AS QtyOnHand,
    ISNULL(ss.QtyAvail, 0)                  AS QtyAvailable,
    ISNULL(cost.UnitCost, 0)                AS UnitCost,
    ISNULL(ss.QtyOnHand, 0) 
        * ISNULL(cost.UnitCost, 0)          AS ExtendedValue,
    ii.BaseUnit                             AS UOM,
    
    -- ── Transaction Velocity & Recency ──
    ISNULL(txn.TxnCount90Days, 0)           AS TxnCount90Days,
    ISNULL(txn.UnitsMovedAbs90Days, 0)      AS UnitsMovedAbs90Days,
    txn.LastTransactionDate,
    DATEDIFF(DAY, txn.LastTransactionDate, GETDATE()) 
                                            AS DaysSinceLastTransaction,
    
    -- ── Last Physical Count ──
    lastPI.LastCountDate,
    lastPI.LastCountBookQty,
    lastPI.LastCountPhysicalQty,
    lastPI.LastCountVarianceQty,
    DATEDIFF(DAY, lastPI.LastCountDate, GETDATE()) 
                                            AS DaysSinceLastCount,
    
    -- ── Item Flags ──
    ii.ItemStatus,
    ii.ItemType,
    CASE 
        WHEN ISNULL(ss.QtyOnHand, 0) = 0 
             AND ISNULL(txn.TxnCount90Days, 0) = 0 
        THEN 'Inactive'
        WHEN ISNULL(txn.TxnCount90Days, 0) >= 20 
        THEN 'High Velocity'
        WHEN ISNULL(txn.TxnCount90Days, 0) >= 5 
        THEN 'Medium Velocity'
        ELSE 'Low Velocity'
    END                                     AS VelocityCategory,
    
    -- ── Count Priority Score (0-100) ──
    -- Value (0-40) + Velocity (0-30) + Staleness (0-30)
    (
        CASE 
            WHEN ISNULL(ss.QtyOnHand, 0) * ISNULL(cost.UnitCost, 0) >= 5000 THEN 40
            WHEN ISNULL(ss.QtyOnHand, 0) * ISNULL(cost.UnitCost, 0) >= 1000 THEN 30
            WHEN ISNULL(ss.QtyOnHand, 0) * ISNULL(cost.UnitCost, 0) >= 250  THEN 20
            WHEN ISNULL(ss.QtyOnHand, 0) * ISNULL(cost.UnitCost, 0) > 0     THEN 10
            ELSE 0
        END
        +
        CASE 
            WHEN ISNULL(txn.TxnCount90Days, 0) >= 20 THEN 30
            WHEN ISNULL(txn.TxnCount90Days, 0) >= 10 THEN 22
            WHEN ISNULL(txn.TxnCount90Days, 0) >= 5  THEN 15
            WHEN ISNULL(txn.TxnCount90Days, 0) >= 1  THEN 8
            ELSE 0
        END
        +
        CASE 
            WHEN lastPI.LastCountDate IS NULL                           THEN 30
            WHEN DATEDIFF(DAY, lastPI.LastCountDate, GETDATE()) > 180  THEN 30
            WHEN DATEDIFF(DAY, lastPI.LastCountDate, GETDATE()) > 90   THEN 22
            WHEN DATEDIFF(DAY, lastPI.LastCountDate, GETDATE()) > 45   THEN 15
            WHEN DATEDIFF(DAY, lastPI.LastCountDate, GETDATE()) > 14   THEN 8
            ELSE 0
        END
    )                                       AS CountPriorityScore

FROM dbo.InventoryItem ii

INNER JOIN dbo.INItemClass ic 
    ON ic.CompanyID = ii.CompanyID 
    AND ic.ItemClassID = ii.ItemClassID

-- ════════════════════════════════════════════════════════════════════
-- INNER JOIN: Only items with warehouse presence appear.
-- Items with no INSiteStatus record have never been stocked and
-- have nothing to count. This eliminates phantom NULL-warehouse rows.
-- Pre-aggregated across SubItemID to prevent row multiplication.
-- ════════════════════════════════════════════════════════════════════
INNER JOIN (
    SELECT
        CompanyID,
        InventoryID,
        SiteID,
        SUM(ISNULL(QtyOnHand, 0))           AS QtyOnHand,
        SUM(ISNULL(QtyAvail, 0))            AS QtyAvail
    FROM dbo.INSiteStatus
    GROUP BY CompanyID, InventoryID, SiteID
) ss 
    ON ss.CompanyID = ii.CompanyID 
    AND ss.InventoryID = ii.InventoryID

INNER JOIN dbo.INSite ins 
    ON ins.CompanyID = ss.CompanyID 
    AND ins.SiteID = ss.SiteID

-- ════════════════════════════════════════════════════════════════════
-- Cost from INCostStatus — weighted average across active cost layers.
-- Tries CostSiteID = SiteID first (warehouse-level costing).
-- If your tenant uses location-level costing, CostSiteID maps to
-- INLocation.LocationID instead — run the pre-deploy validation
-- to confirm which mapping applies.
-- ════════════════════════════════════════════════════════════════════
LEFT JOIN (
    SELECT
        cs.CompanyID,
        cs.InventoryID,
        cs.CostSiteID,
        CASE 
            WHEN SUM(cs.QtyOnHand) > 0 
            THEN SUM(cs.TotalCost) / SUM(cs.QtyOnHand)
            ELSE 0 
        END                                 AS UnitCost
    FROM dbo.INCostStatus cs
    WHERE cs.QtyOnHand > 0
    GROUP BY cs.CompanyID, cs.InventoryID, cs.CostSiteID
) cost 
    ON cost.CompanyID = ii.CompanyID 
    AND cost.InventoryID = ii.InventoryID 
    AND cost.CostSiteID = ss.SiteID

-- ── Transaction stats: single pass for velocity and last txn date ──
LEFT JOIN (
    SELECT 
        t.CompanyID,
        t.InventoryID,
        t.SiteID,
        MAX(r.TranDate)                     AS LastTransactionDate,
        COUNT(DISTINCT CASE 
            WHEN r.TranDate >= DATEADD(DAY, -90, GETDATE()) 
            THEN t.RefNbr 
        END)                                AS TxnCount90Days,
        SUM(CASE 
            WHEN r.TranDate >= DATEADD(DAY, -90, GETDATE()) 
            THEN ABS(ISNULL(t.Qty, 0)) 
            ELSE 0 
        END)                                AS UnitsMovedAbs90Days
    FROM dbo.INTran t
    INNER JOIN dbo.INRegister r 
        ON r.CompanyID = t.CompanyID 
        AND r.DocType = t.DocType 
        AND r.RefNbr = t.RefNbr
    WHERE r.Released = 1
    GROUP BY t.CompanyID, t.InventoryID, t.SiteID
) txn 
    ON txn.CompanyID = ii.CompanyID 
    AND txn.InventoryID = ii.InventoryID 
    AND txn.SiteID = ss.SiteID

-- ── Last physical count: SiteID from INPIHeader (authoritative) ──
LEFT JOIN (
    SELECT 
        d.CompanyID,
        d.InventoryID,
        h.SiteID,
        MAX(h.CountDate)                    AS LastCountDate,
        MAX(CASE WHEN h.CountDate = sub.MaxDate THEN d.BookQty END) 
                                            AS LastCountBookQty,
        MAX(CASE WHEN h.CountDate = sub.MaxDate THEN d.PhysicalQty END) 
                                            AS LastCountPhysicalQty,
        MAX(CASE WHEN h.CountDate = sub.MaxDate THEN d.VarQty END) 
                                            AS LastCountVarianceQty
    FROM dbo.INPIDetail d
    INNER JOIN dbo.INPIHeader h 
        ON h.CompanyID = d.CompanyID 
        AND h.PIID = d.PIID
    INNER JOIN (
        SELECT 
            d2.CompanyID, 
            d2.InventoryID, 
            h2.SiteID,
            MAX(h2.CountDate)               AS MaxDate
        FROM dbo.INPIDetail d2
        INNER JOIN dbo.INPIHeader h2 
            ON h2.CompanyID = d2.CompanyID 
            AND h2.PIID = d2.PIID
        WHERE h2.Status = 'C'
        GROUP BY d2.CompanyID, d2.InventoryID, h2.SiteID
    ) sub 
        ON sub.CompanyID = d.CompanyID 
        AND sub.InventoryID = d.InventoryID 
        AND sub.SiteID = h.SiteID
    WHERE h.Status = 'C'
    GROUP BY d.CompanyID, d.InventoryID, h.SiteID
) lastPI 
    ON lastPI.CompanyID = ii.CompanyID 
    AND lastPI.InventoryID = ii.InventoryID 
    AND lastPI.SiteID = ss.SiteID

WHERE ii.ItemStatus = 'AC'
    AND ii.StkItem = 1
;
GO


-- ============================================================================
-- VIEW 2: ABC CLASSIFICATION
-- (Already filters on QtyOnHand > 0, so no phantom row issue here.
--  Only change: cost join and txn join aligned with View 1 fixes.)
-- ============================================================================

CREATE OR ALTER VIEW dbo.vw_ABCClassification AS
WITH ItemValues AS (
    SELECT
        ii.CompanyID,
        ii.InventoryID,
        ii.InventoryCD,
        ii.Descr                                AS ItemDescription,
        ic.ItemClassCD,
        ic.Descr                                AS ItemClassDescription,
        ins.SiteID,
        ins.SiteCD                              AS WarehouseCD,
        ISNULL(ss.QtyOnHand, 0)                 AS QtyOnHand,
        ISNULL(cost.UnitCost, 0)                AS UnitCost,
        ISNULL(ss.QtyOnHand, 0) 
            * ISNULL(cost.UnitCost, 0)          AS ExtendedValue,
        ii.BaseUnit                             AS UOM,
        ii.ItemStatus
    FROM dbo.InventoryItem ii
    INNER JOIN dbo.INItemClass ic 
        ON ic.CompanyID = ii.CompanyID 
        AND ic.ItemClassID = ii.ItemClassID
    INNER JOIN (
        SELECT
            CompanyID,
            InventoryID,
            SiteID,
            SUM(ISNULL(QtyOnHand, 0))           AS QtyOnHand
        FROM dbo.INSiteStatus
        GROUP BY CompanyID, InventoryID, SiteID
    ) ss 
        ON ss.CompanyID = ii.CompanyID 
        AND ss.InventoryID = ii.InventoryID
    INNER JOIN dbo.INSite ins 
        ON ins.CompanyID = ss.CompanyID 
        AND ins.SiteID = ss.SiteID
    LEFT JOIN (
        SELECT
            cs.CompanyID,
            cs.InventoryID,
            cs.CostSiteID,
            CASE 
                WHEN SUM(cs.QtyOnHand) > 0 
                THEN SUM(cs.TotalCost) / SUM(cs.QtyOnHand)
                ELSE 0 
            END                             AS UnitCost
        FROM dbo.INCostStatus cs
        WHERE cs.QtyOnHand > 0
        GROUP BY cs.CompanyID, cs.InventoryID, cs.CostSiteID
    ) cost 
        ON cost.CompanyID = ii.CompanyID 
        AND cost.InventoryID = ii.InventoryID 
        AND cost.CostSiteID = ss.SiteID
    WHERE ii.ItemStatus = 'AC'
        AND ii.StkItem = 1
        AND ISNULL(ss.QtyOnHand, 0) > 0
),
RankedItems AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY CompanyID, SiteID 
            ORDER BY ExtendedValue DESC
        )                                       AS ValueRank,
        SUM(ExtendedValue) OVER (
            PARTITION BY CompanyID, SiteID 
            ORDER BY ExtendedValue DESC 
            ROWS UNBOUNDED PRECEDING
        )                                       AS CumulativeValue,
        SUM(ExtendedValue) OVER (
            PARTITION BY CompanyID, SiteID
        )                                       AS TotalWarehouseValue,
        COUNT(*) OVER (
            PARTITION BY CompanyID, SiteID
        )                                       AS TotalItemCount
    FROM ItemValues
)
SELECT
    CompanyID,
    InventoryID,
    InventoryCD,
    ItemDescription,
    ItemClassCD,
    ItemClassDescription,
    SiteID,
    WarehouseCD,
    QtyOnHand,
    UnitCost,
    ExtendedValue,
    UOM,
    ValueRank,
    CumulativeValue,
    TotalWarehouseValue,
    TotalItemCount,
    
    CASE 
        WHEN TotalWarehouseValue > 0 
        THEN CAST(ExtendedValue * 100.0 / TotalWarehouseValue AS DECIMAL(5,2))
        ELSE 0 
    END                                         AS PctOfTotalValue,
    
    CASE 
        WHEN TotalWarehouseValue > 0 
        THEN CAST(CumulativeValue * 100.0 / TotalWarehouseValue AS DECIMAL(5,2))
        ELSE 0 
    END                                         AS CumulativePctOfValue,
    
    CASE 
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 80 
        THEN 'A'
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 95 
        THEN 'B'
        ELSE 'C'
    END                                         AS ABCClass,
    
    CASE 
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 80 
        THEN 'Monthly'
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 95 
        THEN 'Quarterly'
        ELSE 'Semi-Annually'
    END                                         AS RecommendedCountFrequency,
    
    CASE 
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 80 
        THEN 12
        WHEN TotalWarehouseValue > 0 
             AND (CumulativeValue - ExtendedValue) * 100.0 / TotalWarehouseValue < 95 
        THEN 4
        ELSE 2
    END                                         AS CountsPerYear

FROM RankedItems
;
GO
