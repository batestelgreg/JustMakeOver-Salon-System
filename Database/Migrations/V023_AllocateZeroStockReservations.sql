/*
    V023_AllocateZeroStockReservations.sql

    Gi-fix ang bug: kung ZERO ang stock sa pag-approve sa requisition,
    ang usp_Inventory_IssueStock wala maghimo og INVENTORY_RESERVATIONS
    row (ang CK_RESERVATIONS_Quantity nagkinahanglan og QuantityReserved > 0).
    Tungod ana, ang allocation loop sa usp_Inventory_ReceiveStock (nga
    mo-search ra sa reservation rows) wala makakita sa requisition, mao
    nga ang detail nagpabilin nga 'Pending' ug dili mo-gawas sa Delivery
    (Allocated Requisitions) bisan nadawat na ang stock.

    Karon: ang allocation loop mo-apil usab sa Approved requisition
    details nga Pending ug walay Active reservation, ug mo-INSERT og
    reservation row (QuantityReserved = allocated qty, > 0).

    Ang allocation order kay FIFO sa requisition (RequestDate) para sa duha ka
    source, dili ReservationDate vs RequestDate nga gi-mix.
    Parehas ra ang tanang ubang logic sa V013 (partial receive, cap,
    permission, notification, reorder check).
    Re-runnable (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

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

    -- Kani nga cursor kay duha ka source:
    --   (a) existing Active reservations nga kulang pa (partial), ug
    --   (b) Approved requisition details nga Pending ug WALAY Active
    --       reservation (zero-stock case; ang CK_RESERVATIONS_Quantity
    --       wala motugot og 0, mao nga wala'y row ang gihimo sa Issue).
    DECLARE waitingCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT w.ReservationID, w.RequisitionDetailID, w.RequisitionID,
               w.QuantityNeeded, w.RequestorUserID
        FROM (
        SELECT r.ReservationID, r.RequisitionDetailID, rd.RequisitionID,
               (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) AS QuantityNeeded,
               req.RequestorUserID, req.RequestDate AS SortDate
        FROM INVENTORY_RESERVATIONS r
        INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
        INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
        INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
        WHERE i.ItemID = @ItemID
          AND r.Status = 'Active'
          AND (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) > 0
        UNION ALL
        SELECT CAST(NULL AS INT), rd.RequisitionDetailID, rd.RequisitionID,
               ISNULL(rd.QuantityApproved, rd.QuantityRequested),
               req.RequestorUserID, req.RequestDate
        FROM REQUISITION_DETAILS rd
        INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
        WHERE rd.ItemID = @ItemID
          AND req.Status = 'Approved'
          AND rd.Status = 'Pending'
          AND NOT EXISTS (SELECT 1 FROM INVENTORY_RESERVATIONS x
                          WHERE x.RequisitionDetailID = rd.RequisitionDetailID
                            AND x.Status = 'Active')
        ) AS w
        ORDER BY w.SortDate;

    OPEN waitingCursor;
    FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @AvailableNow INT =
            (SELECT (QuantityOnHand - QuantityReserved) FROM INVENTORY WHERE ItemID = @ItemID);

        IF @AvailableNow <= 0
            BREAK;

        DECLARE @AllocateQty INT = CASE WHEN @AvailableNow < @ShortageQty THEN @AvailableNow ELSE @ShortageQty END;

        -- Kani nga branch: bag-ong reservation row kung wala pa (zero-stock
        -- case), kung naa na, i-dugang lang ang QuantityReserved.
        IF @ReservationID IS NULL
            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@ReservationDetailID, @AllocateQty, SYSDATETIME(), 'Active');
        ELSE
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
