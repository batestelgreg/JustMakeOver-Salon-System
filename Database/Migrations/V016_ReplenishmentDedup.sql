/*
    V016_ReplenishmentDedup.sql

    Gi-fix ang duha ka Replenishment (RepF) issues:

    1) DUPLICATE RepF
       Ang shortage branch sa usp_Inventory_IssueStock kay direkta mo-INSERT
       og bag-ong RepF bisan naa nay Pending RepF para sa parehas nga item.
       Ang dedup check naa ra sa usp_Inventory_CheckReorderPoint.
       Karon: i-merge ang shortage sa existing Pending RepF nga wala pa
       ma-cover og Purchase Request; kung naa nay PR, bag-ong RepF.

    2) WALAY RepF kung Adjust ra
       Ang usp_Inventory_AdjustStock wala mo-check sa reorder point.
       Karon: human sa commit, tawgon ang usp_Inventory_CheckReorderPoint
       (kini ra mo-create kung Available <= ReorderPoint, so ang pag-add
       og stock dili mo-trigger).

    Dugang: usa ka beses nga cleanup sa mga na-existing duplicate Pending
    RepF nga parehas og item + parehas og origin, walay PR, ug walay
    receiving evidence. Re-runnable ang tanan (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

/* 
   1. ISSUE STOCK — shortage dedup/merge
  */
CREATE OR ALTER PROCEDURE dbo.usp_Inventory_IssueStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityRequested INT,
    @RequisitionID INT = NULL,
    @EstimatedRestockDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityRequested IS NULL OR @QuantityRequested <= 0
        THROW 50315, 'The requested quantity must be greater than zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.update'
    )
        THROW 50316, 'You do not have permission to issue stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50317, 'The item is inactive or was not found.', 1;

    DECLARE @RequestorUserID INT = @ActorUserID;
    DECLARE @RequisitionDetailID INT = NULL;
    DECLARE @RemainingQty INT = @QuantityRequested;

    -- Kini nga block kay para sa approved ReF nga source sa issuance.
    IF @RequisitionID IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM REQUISITIONS WHERE RequisitionID = @RequisitionID AND Status = 'Approved')
            THROW 50318, 'Only an approved requisition can be issued stock.', 1;

        SELECT @RequestorUserID = r.RequestorUserID
        FROM REQUISITIONS r
        WHERE r.RequisitionID = @RequisitionID;

        SELECT TOP (1) @RequisitionDetailID = rd.RequisitionDetailID,
                       @RemainingQty = ISNULL(rd.QuantityApproved, rd.QuantityRequested)
        FROM REQUISITION_DETAILS rd
        WHERE rd.RequisitionID = @RequisitionID
          AND rd.ItemID = @ItemID
          AND rd.Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        IF @RequisitionDetailID IS NULL
            THROW 50319, 'The requisition does not include this item or it is already fulfilled.', 1;

        DECLARE @AlreadyReserved INT = ISNULL((
            SELECT SUM(r.QuantityReserved)
            FROM INVENTORY_RESERVATIONS r
            WHERE r.RequisitionDetailID = @RequisitionDetailID AND r.Status = 'Active'
        ), 0);

        SET @RemainingQty = @RemainingQty - @AlreadyReserved;

        IF @RemainingQty <= 0
            THROW 50328, 'This requisition item is already fully reserved.', 1;
    END;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Available INT = @OnHand - @Reserved;

    -- Kini nga case kay para sa sufficient stock: full reservation lang.
    IF @Available >= @RemainingQty
    BEGIN
        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @RemainingQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @RemainingQty, @Reserved, @Reserved + @RemainingQty,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CASE WHEN @RequisitionID IS NULL
                     THEN CONCAT('Stock reserved for issuance: ', @RemainingQty, ' unit(s).')
                     ELSE N'Stock reserved for approved requisition.'
                END, SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            UPDATE REQUISITION_DETAILS
            SET Status = 'Approved'
            WHERE RequisitionDetailID = @RequisitionDetailID;

            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @RemainingQty, SYSDATETIME(), 'Active');
        END;

        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_RESERVED', 'Stock reserved',
                'Your requested item has been reserved and is ready for delivery.',
                'REQUISITION', @RequisitionID, 0, SYSDATETIME());

        COMMIT TRANSACTION;

        -- Reorder-point diamond: kung at/below reorder point -> low-stock + RepF.
        EXEC dbo.usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;

        SELECT 'Reserved' AS Outcome, @RemainingQty AS ReservedQuantity, 0 AS ShortageQuantity, NULL AS RepFID;
        RETURN;
    END;

    -- Kini nga case kay para sa insufficient stock: partial reservation + shortage.
    DECLARE @ShortageQty INT = @RemainingQty - @Available;

    IF @Available > 0
    BEGIN
        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @Available, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @Available, @Reserved, @Reserved + @Available,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CONCAT('Partial reservation: only ', @Available, ' of ', @RemainingQty,
                       ' unit(s) available. Replenishment request generated.'), SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @Available, SYSDATETIME(), 'Active');
        END;
    END;

    -- Kini nga RepF kay para sa shortage: i-merge sa existing Pending RepF
    -- nga wala pa naay PR, para dili ma-duplicate ang replenishment.
    DECLARE @NewRepFID INT = NULL;

    IF @ShortageQty > 0
    BEGIN
        SELECT TOP (1) @NewRepFID = rr.RepFID
        FROM REPLENISHMENT_REQUESTS rr
        WHERE rr.ItemID = @ItemID
          AND rr.Status = 'Pending'
          AND (rr.OriginRequisitionID IS NULL OR rr.OriginRequisitionID = @RequisitionID)
          AND NOT EXISTS
          (
              SELECT 1 FROM PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID
          )
        ORDER BY rr.RepFID;

        IF @NewRepFID IS NOT NULL
        BEGIN
            -- Idugang ang shortage sa existing request ug tipigi ang origin.
            UPDATE REPLENISHMENT_REQUESTS
            SET QuantityNeeded = QuantityNeeded + @ShortageQty,
                OriginRequisitionID = COALESCE(OriginRequisitionID, @RequisitionID)
            WHERE RepFID = @NewRepFID;
        END
        ELSE
        BEGIN
            INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status, OriginRequisitionID)
            VALUES (@ItemID, @ShortageQty, SYSDATETIME(), 'Pending', @RequisitionID);
            SET @NewRepFID = SCOPE_IDENTITY();
        END;
    END;

    IF @RequisitionDetailID IS NOT NULL
    BEGIN
        UPDATE REQUISITION_DETAILS
        SET Status = CASE WHEN @Available > 0 THEN 'Partially Fulfilled' ELSE 'Pending' END
        WHERE RequisitionDetailID = @RequisitionDetailID;
    END;

    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, 7, CAST(SYSDATETIME() AS DATE)));

    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT('Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                   CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME());

    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'STOCK_SHORTAGE', 'Stock shortage needs replenishment',
           CONCAT('A shortage of ', @ShortageQty, ' unit(s) was noted on an item (',
                  i.ItemName, '). A replenishment request was generated.'),
           'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME()
    FROM USERS u
    INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    INNER JOIN ITEMS i ON i.ItemID = @ItemID
    WHERE u.IsActive = 1
      AND p.PermissionCode = N'inventory.view'
      AND u.UserID <> @RequestorUserID;

    COMMIT TRANSACTION;
    SELECT 'Shortage' AS Outcome, @Available AS ReservedQuantity, @ShortageQty AS ShortageQuantity, @NewRepFID AS RepFID;
END;
GO

/* 
   2. ADJUST STOCK — reorder check human sa commit
    */
CREATE OR ALTER PROCEDURE dbo.usp_Inventory_AdjustStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityChange INT,
    @Remarks NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityChange = 0
        THROW 50312, 'The adjustment quantity cannot be zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.adjust'
    )
        THROW 50313, 'You do not have permission to adjust inventory stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50315, 'The item is inactive or was not found.', 1;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);

    IF @OnHand IS NULL
        THROW 50316, 'No stock record exists for this item yet.', 1;

    IF (@OnHand + @QuantityChange) < @Reserved
        THROW 50314, 'The adjustment would make the stock lower than the reserved quantity.', 1;

    UPDATE INVENTORY
    SET QuantityOnHand = QuantityOnHand + @QuantityChange, LastUpdated = SYSDATETIME()
    WHERE ItemID = @ItemID;

    DECLARE @AdjustmentLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Adjustment', @QuantityChange, @OnHand, @OnHand + @QuantityChange, 'ADJUSTMENT', 0,
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Inventory quantity manually adjusted.'), SYSDATETIME());

    SET @AdjustmentLogID = SCOPE_IDENTITY();
    UPDATE INVENTORY_LOGS
    SET ReferenceID = @AdjustmentLogID
    WHERE InventoryLogID = @AdjustmentLogID AND ReferenceID = 0;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ADJUSTED',
            CONCAT('Stock adjusted by ', @QuantityChange, ' for item ID ', @ItemID, '.'));

    COMMIT TRANSACTION;

    -- Diri na mo-gawas ang low-stock RepF kung ang adjustment nagpahinabo
    -- nga Available <= ReorderPoint. Ang pag-add og stock dili mo-trigger.
    EXEC dbo.usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;
END;
GO

/* 
   3. ONE-TIME CLEANUP sa na-existing duplicate Pending RepF

   Rule: parehas nga ItemID + parehas nga OriginRequisitionID,
   Pending, walay receiving, walay PR, ug walay stock-in log.
   Ang pinaka-una nga RepFID maoy magpabilin; ang uban i-merge
   ang QuantityNeeded dayon i-delete. Kung lahi ang origin (lain nga
   requisition) kay dili i-merge para dili mawala ang trace.
 */
DECLARE @Merge TABLE
(
    KeepRepFID INT PRIMARY KEY,
    ItemID INT NOT NULL,
    OriginRequisitionID INT NULL,
    TotalNeeded INT NOT NULL
);

INSERT INTO @Merge (KeepRepFID, ItemID, OriginRequisitionID, TotalNeeded)
SELECT MIN(rr.RepFID), rr.ItemID, rr.OriginRequisitionID, SUM(rr.QuantityNeeded)
FROM dbo.REPLENISHMENT_REQUESTS rr
WHERE rr.Status = 'Pending'
  AND rr.QuantityReceived = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID)
  AND NOT EXISTS (
      SELECT 1 FROM dbo.INVENTORY_LOGS l
      WHERE l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID = rr.RepFID
  )
GROUP BY rr.ItemID, rr.OriginRequisitionID
HAVING COUNT(*) > 1;

-- Total sa nahabilin nga RepF.
UPDATE rr
SET QuantityNeeded = m.TotalNeeded
FROM dbo.REPLENISHMENT_REQUESTS rr
INNER JOIN @Merge m ON m.KeepRepFID = rr.RepFID;

-- Ang duplicate nga notifications kay tangtangon daan.
DELETE n
FROM dbo.NOTIFICATIONS n
INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
    ON rr.RepFID = n.RelatedEntityID
   AND n.RelatedEntityType = 'REPLENISHMENT_REQUEST'
INNER JOIN @Merge m
    ON m.ItemID = rr.ItemID
   AND (m.OriginRequisitionID = rr.OriginRequisitionID
        OR (m.OriginRequisitionID IS NULL AND rr.OriginRequisitionID IS NULL))
WHERE rr.RepFID <> m.KeepRepFID
  AND rr.Status = 'Pending'
  AND rr.QuantityReceived = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID);

-- Dayon ang duplicates mismo.
DELETE rr
FROM dbo.REPLENISHMENT_REQUESTS rr
INNER JOIN @Merge m
    ON m.ItemID = rr.ItemID
   AND (m.OriginRequisitionID = rr.OriginRequisitionID
        OR (m.OriginRequisitionID IS NULL AND rr.OriginRequisitionID IS NULL))
WHERE rr.RepFID <> m.KeepRepFID
  AND rr.Status = 'Pending'
  AND rr.QuantityReceived = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID)
  AND NOT EXISTS (
      SELECT 1 FROM dbo.INVENTORY_LOGS l
      WHERE l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID = rr.RepFID
  );
GO
