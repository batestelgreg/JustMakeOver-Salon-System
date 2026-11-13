/* ================================================================
   V004 - RECEIVING MODULE (flowchart Figure 8.B)
   ----------------------------------------------------------------
   Kani nga migration kay para sa Receiving module:
     1. usp_Receiving_GetPending  - mga RepF nga wala pa madawatan.
     2. usp_Receiving_GetHistory  - Stock In history (RR-/RefP-).
   ANG SUBMIT KAY WALAY BAG-ONG PROC - mo-reuse sa
   usp_Inventory_ReceiveStock (V003) mao nga usa ra ang engine
   sa pag-increase sa stock (walay duplication sa receiving flow).
   Idempotent kini: CREATE OR ALTER ra, walay data change.
   ================================================================ */

/* ----------------------------------------------------------------
   1. PENDING QUEUE - mga RepF (Status = 'Pending') nga gipa-abot
      pa sa Receiving. Kini ang mga linya nga may "Receive" button.
   ---------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE usp_Receiving_GetPending
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
           inv.QuantityOnHand, (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    INNER JOIN INVENTORY inv ON inv.ItemID = f.ItemID
    WHERE f.Status = 'Pending'
    ORDER BY f.DateGenerated ASC;
END;
GO

/* ----------------------------------------------------------------
   2. HISTORY - mga actual nga Stock In nga narecords na sa
      Receiving (ReferenceType RECEIVING o REPLENISHMENT ra -
      dili apil ang SEED/INITIAL kay dili man na tinuod nga
      receiving). Ang reference kay computed: RR-#### o RefP-####,
      walay fake numbers.
   ---------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE usp_Receiving_GetHistory
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
        THROW 50341, 'You do not have permission to view the receiving history.', 1;

    SELECT TOP (50) l.InventoryLogID, l.TransactionDate, i.ItemName, i.ItemCode,
           l.QuantityChange, l.PreviousQuantity, l.NewQuantity, l.Remarks,
           CONCAT(u.FirstName, ' ', u.LastName) AS UserName,
           CASE
               WHEN l.ReferenceType = 'RECEIVING' AND l.ReferenceID IS NOT NULL
                   THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                   THEN 'RefP-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               ELSE NULL
           END AS ReferenceDisplay,
           CASE
               WHEN l.ReferenceType = 'REPLENISHMENT' THEN 'Replenishment'
               ELSE 'Manual receipt'
           END AS SourceDisplay
    FROM INVENTORY_LOGS l
    INNER JOIN ITEMS i ON i.ItemID = l.ItemID
    LEFT JOIN USERS u ON u.UserID = l.UserID
    WHERE l.TransactionType = 'Stock In'
      AND l.ReferenceType IN ('RECEIVING', 'REPLENISHMENT')
    ORDER BY l.TransactionDate DESC, l.InventoryLogID DESC;
END;
GO

/* ----------------------------------------------------------------
   3. ITEMS - active nga items nga may live stock para sa manual
      receiving ("Receive without reference" nga dalan). Usay
      receiving engine ra gihapon ang gamiton sa submit.
   ---------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE usp_Receiving_GetItems
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
        THROW 50342, 'You do not have permission to view the receiving items.', 1;

    SELECT i.ItemID, i.ItemCode, i.ItemName, i.UnitOfMeasure,
           inv.QuantityOnHand, (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable
    FROM ITEMS i
    INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
    WHERE i.IsActive = 1
    ORDER BY i.ItemName ASC;
END;
GO

/* ----------------------------------------------------------------
   NOTE SA PERMISSION:
   Ang submit mogamit sa usp_Inventory_ReceiveStock nga adunay
   permission check sa inventory.update O receiving.manage (V003
   ang ga-manage niini). Busa ang roles nga may receiving.manage
   makasubmit. Kani nga single-engine nga approach kay para
   WALAY DUPLICATION sa receiving flow ug sa stock movements.
   ---------------------------------------------------------------- */
