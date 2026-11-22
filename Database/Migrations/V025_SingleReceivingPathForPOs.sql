/*
    V025_SingleReceivingPathForPOs.sql

    Gi-fix ang double receiving path:

    Human ma-Record Delivery Check sa Purchasing, ang parehas nga stock
    mogawas sa DUHA ka lugar sa Receiving page:
      (1) "Checked Supplier Deliveries" (usp_Purchasing_GetCheckedDRQueue)
      (2) "Pending to Receive" (usp_Receiving_GetPending, ang RepF)
    Kung i-Receive ang RepF sa (2), ang row sa (1) dili mawala kay walay
    Receiving Memo nga gihimo, ug kung i-Receive pa kini unya, mo-THROW
    ang 50533 ("receipts outside the checked-DR workflow").

    Karon:
    1. usp_Receiving_GetPending: ang RepF nga naay PO nga 'Sent to
       Supplier' o 'Partially Delivered' dili na ipakita dinhi. Kinahanglan
       kini i-receive pinaagi sa checked DR (usa ra ang dalan).
    2. usp_Purchasing_GetCheckedDRQueue: ipakita lang ang DR kung ang
       RepF niini Pending pa. Ang DR sa RepF nga na-receive na (Processed/
       Cancelled) dili na mo-gawas isip stale row.

    Wala'y data nga gi-usab. Re-runnable (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Receiving_GetPending
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'receiving.view'
    )
        THROW 50340, 'You do not have permission to view the receiving queue.', 1;

    SELECT f.RepFID, f.ItemID, i.ItemCode, i.ItemName, i.UnitOfMeasure,
           f.QuantityNeeded, f.DateGenerated,
           inv.QuantityOnHand, (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable,
           f.QuantityReceived
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    INNER JOIN INVENTORY inv ON inv.ItemID = f.ItemID
    WHERE f.Status = 'Pending'
      -- Kani nga RepF naay PO nga naa na sa supplier: i-receive kini
      -- pinaagi sa Checked Supplier Deliveries, dili direkta.
      AND NOT EXISTS
      (
          SELECT 1
          FROM PURCHASE_REQUESTS pr
          INNER JOIN PURCHASE_ORDERS po ON po.PRID = pr.PRID
          WHERE pr.RepFID = f.RepFID
            AND po.Status IN ('Sent to Supplier', 'Partially Delivered')
      )
    ORDER BY f.DateGenerated ASC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_GetCheckedDRQueue
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('receiving.view', 'receiving.manage')
    )
        THROW 50530, 'Receiving permission is required.', 1;

    SELECT
        dr.DRID,
        dr.POID,
        tr.SupplierDRNumber,
        pr.RepFID,
        dd.ItemID,
        i.ItemCode,
        i.ItemName,
        dd.QuantityAccepted,
        dr.DeliveryDate,
        dr.Notes
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
    INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
    INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
    INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
    -- Kani nga join kay para ang RepF nga na-receive na (Processed/
    -- Cancelled) dili na mo-gawas ang DR niini.
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID AND rr.Status = 'Pending'
    INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
    WHERE dd.QuantityAccepted > 0
      AND dr.Status <> 'Rejected'
      AND po.Status IN ('Sent to Supplier', 'Partially Delivered')
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.RECEIVING_MEMOS rm
          WHERE rm.DRID = dr.DRID
      )
    ORDER BY dr.DeliveryDate, dr.DRID;
END;
GO
