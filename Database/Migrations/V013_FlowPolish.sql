/*
   V013 - Flow polish (audit batch)

   Kani nga migration kay para sa mga kulang/bug nga na-discover sa
   flowchart audit:

     1. STOCK_ALLOCATED message: apil na ang requisition ID para
        mahibaw-an sa requester kung asa nga request na-allocate.
     2. Delivery "archives": ang Fulfilled requisition ma-mark na
        og ArchivedAt (permanent history gihapon, walay deletion).
     3. Backfill sa daan nga Fulfilled requisitions (ArchivedAt).

   Kini idempotent: guarded ALTER + CREATE OR ALTER ra.
   THROW range: 50420-50429.
*/

USE JustMakeOverSalonDB;
GO

/*
   1. ARCHIVE TRACKING — ang flowchart kay "System marks requisition
      Fulfilled, archives records". Kani nga column kay explicit na
      nga archive marker samtang nagpabilin ang tanang history rows.
*/
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.REQUISITIONS')
      AND name = 'ArchivedAt'
)
    ALTER TABLE dbo.REQUISITIONS
        ADD ArchivedAt DATETIME NULL;
GO

-- Kani nga backfill kay para sa daan nga Fulfilled nga wala pa'y marker.
UPDATE dbo.REQUISITIONS
SET ArchivedAt = SYSDATETIME()
WHERE Status = N'Fulfilled'
  AND ArchivedAt IS NULL;
GO

/*
   2. ARCHIVE TRIGGER — kung ma-Fulfilled ang requisition (delivery
      completion), automatic nga ma-set ang ArchivedAt. Dili kini
      mo-touch sa ubang status.
*/
CREATE OR ALTER TRIGGER dbo.trg_REQUISITIONS_SetArchivedAt
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status = N'Fulfilled'
          AND d.Status <> N'Fulfilled'
    )
        RETURN;

    UPDATE r
    SET ArchivedAt = SYSDATETIME()
    FROM dbo.REQUISITIONS r
    INNER JOIN inserted i ON i.RequisitionID = r.RequisitionID
    INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
    WHERE i.Status = N'Fulfilled'
      AND d.Status <> N'Fulfilled'
      AND r.ArchivedAt IS NULL;
END;
GO

/*
   3. RECEIVE STOCK — re-emit gikan sa V011 nga may usa ka kausaban:
      ang STOCK_ALLOCATED notification message kay naa na'y
      requisition ID (RF-####) para klaro ang link sa request.
      Parehas ra ang tanang logic (partial receive, cap, allocation,
      permission, reorder check).
*/
CREATE OR ALTER PROCEDURE dbo.usp_Inventory_ReceiveStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityReceived INT,
    @RepFID INT = NULL,
    @Remarks NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityReceived IS NULL OR @QuantityReceived <= 0
        THROW 50320, 'The received quantity must be greater than zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'receiving.manage'
    )
        THROW 50321, 'You do not have permission to record received stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50322, 'The item is inactive or was not found.', 1;

    IF @RepFID IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE RepFID = @RepFID AND ItemID = @ItemID)
        THROW 50323, 'The replenishment request does not match this item.', 1;

    -- Kani nga guard kay para sa partial receive: dili molapas ang
    -- nadawat sa remaining needed sa RepF (over-receive cap).
    IF @RepFID IS NOT NULL
    BEGIN
        DECLARE @RepFRemaining INT = (
            SELECT f.QuantityNeeded - f.QuantityReceived
            FROM REPLENISHMENT_REQUESTS f
            WHERE f.RepFID = @RepFID AND f.Status = N'Pending'
        );

        IF @RepFRemaining IS NULL
            THROW 50410, 'The replenishment request is no longer pending.', 1;

        IF @QuantityReceived > @RepFRemaining
            THROW 50411, 'The received quantity cannot exceed the remaining needed quantity for this replenishment request.', 1;
    END

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);

    -- Kani nga step kay para ma-record ang RIM ug mo-increase ang balance.
    UPDATE INVENTORY
    SET QuantityOnHand = QuantityOnHand + @QuantityReceived, LastUpdated = SYSDATETIME()
    WHERE ItemID = @ItemID;

    -- Kani nga insert kay para sa receiving log. Kung wala nga RepF,
    -- ang log row mismo ang Receiving Record (RR-####) — self-referencing.
    DECLARE @ReceiveLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Stock In', @QuantityReceived, @OnHand, @OnHand + @QuantityReceived,
            CASE WHEN @RepFID IS NULL THEN 'RECEIVING' ELSE 'REPLENISHMENT' END, ISNULL(@RepFID, 0),
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Items received and added to inventory.'), SYSDATETIME());

    -- Kani nga update kay para mahimong RR-#### ang reference niini.
    SET @ReceiveLogID = SCOPE_IDENTITY();
    UPDATE INVENTORY_LOGS
    SET ReferenceID = @ReceiveLogID
    WHERE InventoryLogID = @ReceiveLogID AND ReferenceID = 0;

    -- Kani nga update kay para sa PARTIAL receive: ang RepF mo-pabilin
    -- Pending hangtod ma-kompleto ang QuantityNeeded, ug naa na'y
    -- QuantityReceived tracking.
    IF @RepFID IS NOT NULL
    BEGIN
        UPDATE REPLENISHMENT_REQUESTS
        SET QuantityReceived = QuantityReceived + @QuantityReceived,
            Status = CASE
                WHEN (QuantityReceived + @QuantityReceived) >= QuantityNeeded THEN 'Processed'
                ELSE 'Pending'
            END
        WHERE RepFID = @RepFID AND Status = 'Pending';
    END

    -- Kani nga allocation loop kay para sa mga waiting reservations sa item.
    DECLARE @ReservationID INT;
    DECLARE @ReservationDetailID INT;
    DECLARE @ReservationRequisitionID INT;
    DECLARE @ShortageQty INT;
    DECLARE @RequestorUserID INT;

    DECLARE waitingCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.ReservationID, r.RequisitionDetailID, rd.RequisitionID,
               (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) AS QuantityNeeded,
               req.RequestorUserID
        FROM INVENTORY_RESERVATIONS r
        INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
        INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
        INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
        WHERE i.ItemID = @ItemID
          AND r.Status = 'Active'
          AND (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) > 0
        ORDER BY r.ReservationDate;

    OPEN waitingCursor;
    FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @AvailableNow INT =
            (SELECT (QuantityOnHand - QuantityReserved) FROM INVENTORY WHERE ItemID = @ItemID);

        IF @AvailableNow <= 0
            BREAK;

        DECLARE @AllocateQty INT = CASE WHEN @AvailableNow < @ShortageQty THEN @AvailableNow ELSE @ShortageQty END;

        UPDATE INVENTORY_RESERVATIONS
        SET QuantityReserved = QuantityReserved + @AllocateQty
        WHERE ReservationID = @ReservationID;

        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @AllocateQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        -- Kani nga update kay para sa detail status: approved kung kompleto na.
        UPDATE REQUISITION_DETAILS
        SET Status = CASE WHEN (@ShortageQty - @AllocateQty) = 0 THEN 'Approved' ELSE 'Partially Fulfilled' END
        WHERE RequisitionDetailID = @ReservationDetailID;

        -- Kani nga notification kay para sa requester: allocated ug ready
        -- for delivery. Ang requisition ID kay apil na sa message para
        -- klaro kung asa nga request gi-allocate ang nadawat nga stock.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_ALLOCATED', 'Stock allocated to your request',
                CONCAT('Received stock was allocated to requisition #', @ReservationRequisitionID,
                       ' (', @AllocateQty, ' unit(s)). It is ready for delivery.'),
                'REQUISITION', @ReservationRequisitionID, 0, SYSDATETIME());

        FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;
    END

    CLOSE waitingCursor;
    DEALLOCATE waitingCursor;

    COMMIT TRANSACTION;

    -- Kani nga reorder check kay gimana sa linya aron naka-commit na ang allocation.
    DECLARE @OnHandFinal INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @ReservedFinal INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @AvailableFinal INT = @OnHandFinal - @ReservedFinal;
    DECLARE @ReorderPoint INT = (SELECT ReorderPoint FROM ITEMS WHERE ItemID = @ItemID);

    IF @AvailableFinal <= @ReorderPoint
       AND (@ReorderPoint - @AvailableFinal) > 0
       AND NOT EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE ItemID = @ItemID AND Status = 'Pending')
    BEGIN
        INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
        VALUES (@ItemID, (@ReorderPoint - @AvailableFinal), SYSDATETIME(), 'Pending');

        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT u.UserID, 'LOW_STOCK', 'Low stock alert',
               'The stock of an item reached its reorder point. A replenishment request was generated.',
               'ITEM', @ItemID, 0, SYSDATETIME()
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';
    END
END;
GO
