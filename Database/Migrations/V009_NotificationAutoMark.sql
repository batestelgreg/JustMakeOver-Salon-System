/* ================================================================
   V009 - NOTIFICATION AUTO-MARK ON ACTION ACCOMPLISHED
   ----------------------------------------------------------------
   Kani nga migration kay para sa auto-mark-as-read sa mga
   action-required notifications KUNG na-accomplish na ang ilang
   target action (Figure 6/7/8 workflow). Kung wala pay action
   nga gibuhat, pabilin gihapon unread.

   Rules (single source of truth = DB triggers, mao nga bisan
   unsaon pag-accomplish sa action - app ops, procs, o direct
   DB update sa testing - mo-auto-mark gyud):
     1. REQUISITION_SUBMITTED (review action) -> auto-mark kung ang
        requisition na-approve, na-reject, o na-cancel na.
     2. STOCK_SHORTAGE (RefP receiving action) -> auto-mark kung ang
        RepF na-receive na (Status = 'Processed').
     3. LOW_STOCK (restock action) -> auto-mark kung ang item stock
        balik na sa ibabaw sa reorder point.

   Ang mga FYI notifications (REQUISITION_APPROVED, REJECTED,
   STOCK_RESERVED sa requestor) kay dili apil - ang ilang
   "accomplished action" kay ang delivery, wala pa implemented.

   Kani nga migration idempotent (CREATE OR ALTER + guarded
   backfill). Walay THROW range nga bag-o diri.
   ================================================================ */

USE JustMakeOverSalonDB;
GO

/* ================================================================
   1. TRIGGER: REQUISITIONS - auto-mark sa review notifications
      kung ma-resolve na ang requisition (Approved/Rejected/
      Cancelled).
   ================================================================ */
CREATE OR ALTER TRIGGER trg_REQUISITIONS_AutoMarkNotifications
ON REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga guard kay para mo-fire lang kung naay status change
    -- (dili mo-uban ang ubang column updates ug multi-row updates
    -- nga wala'y status transition).
    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status <> d.Status
    )
        RETURN;

    -- Kani nga mark kay para sa TANANG recipients (ang review action
    -- kay resolved na system-wide - wala na'y kinahanglan mo-review).
    -- Kani nga ReadAt kay required sa CK_NOTIFICATIONS_ReadState
    -- constraint (IsRead=1 => ReadAt NOT NULL).
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType = 'REQUISITION_SUBMITTED'
      AND n.RelatedEntityType = 'REQUISITION'
      AND i.Status IN ('Approved', 'Rejected', 'Cancelled')
      AND n.IsRead = 0;
END;
GO

/* ================================================================
   2. TRIGGER: REPLENISHMENT_REQUESTS - auto-mark sa shortage
      notifications kung na-receive na ang RepF (Status =
      'Processed', giset sa usp_Inventory_ReceiveStock).
   ================================================================ */
CREATE OR ALTER TRIGGER trg_REPLENISHMENT_REQUESTS_AutoMarkNotifications
ON REPLENISHMENT_REQUESTS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RepFID = i.RepFID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RepFID = n.RelatedEntityID
    WHERE n.NotificationType = 'STOCK_SHORTAGE'
      AND n.RelatedEntityType = 'REPLENISHMENT_REQUEST'
      AND i.Status = 'Processed'
      AND n.IsRead = 0;
END;
GO

/* ================================================================
   3. TRIGGER: INVENTORY - auto-mark sa low-stock notifications
      kung ang item stock balik na sa ibabaw sa reorder point
      (pagkahuman sa receiving).
   ================================================================ */
CREATE OR ALTER TRIGGER trg_INVENTORY_AutoMarkLowStockNotifications
ON INVENTORY
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga mark kay para sa LOW_STOCK notifs nga ang ilang item
    -- okay na: available (on hand - reserved) > reorder point.
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.ItemID = n.RelatedEntityID
    INNER JOIN ITEMS it ON it.ItemID = i.ItemID
    WHERE n.NotificationType = 'LOW_STOCK'
      AND n.RelatedEntityType = 'ITEM'
      AND n.IsRead = 0
      AND (i.QuantityOnHand - i.QuantityReserved) > it.ReorderPoint;
END;
GO

/* ================================================================
   4. BACKFILL - one-time catch-up sa mga notifs nga ang ilang
      action resolved na pero unread pa (idempotent: unread ra ang
      ma-mark, repeat = no-op).
   ================================================================ */

-- Kani nga backfill kay para sa REQUISITION_SUBMITTED notifs nga
-- ang requisition resolved na.
UPDATE n
SET IsRead = 1, ReadAt = SYSDATETIME()
FROM NOTIFICATIONS n
INNER JOIN REQUISITIONS r ON r.RequisitionID = n.RelatedEntityID
WHERE n.NotificationType = 'REQUISITION_SUBMITTED'
  AND n.RelatedEntityType = 'REQUISITION'
  AND r.Status IN ('Approved', 'Rejected', 'Cancelled')
  AND n.IsRead = 0;
GO

-- Kani nga backfill kay para sa STOCK_SHORTAGE notifs nga ang
-- RepF processed na.
UPDATE n
SET IsRead = 1, ReadAt = SYSDATETIME()
FROM NOTIFICATIONS n
INNER JOIN REPLENISHMENT_REQUESTS f ON f.RepFID = n.RelatedEntityID
WHERE n.NotificationType = 'STOCK_SHORTAGE'
  AND n.RelatedEntityType = 'REPLENISHMENT_REQUEST'
  AND f.Status = 'Processed'
  AND n.IsRead = 0;
GO

-- Kani nga backfill kay para sa LOW_STOCK notifs nga ang item
-- okay na sa reorder point.
UPDATE n
SET IsRead = 1, ReadAt = SYSDATETIME()
FROM NOTIFICATIONS n
INNER JOIN ITEMS it ON it.ItemID = n.RelatedEntityID
INNER JOIN INVENTORY inv ON inv.ItemID = it.ItemID
WHERE n.NotificationType = 'LOW_STOCK'
  AND n.RelatedEntityType = 'ITEM'
  AND n.IsRead = 0
  AND (inv.QuantityOnHand - inv.QuantityReserved) > it.ReorderPoint;
GO
