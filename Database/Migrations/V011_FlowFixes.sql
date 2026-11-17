/*
   V011 - Flow fixes (Consolidated Fix List 1-9)

   Kani nga migration kay para sa mga flow fixes nga na-discover
   sa system audit ug manual testing:

     1. Partial receive sa RepF: ang RepF dili dayon ma-'Processed'
        kung kulang pa ang nadawat — naay QuantityReceived tracking,
        mo-cap sa remaining needed, ug mobalik gihapon sa pending
        queue hangtod ma-kompleto.
     2. RepF origin trace: OriginRequisitionID column (ang
        requisition nga nag-generate sa shortage).
     3. Allocated-ready notification (REQUISITION_ALLOCATED) sa
        delivery.view users + auto-mark pag Generate AR (trigger).
     4. Cancel requisition notification (requestor ug stakeholders).
     5. STOCK_SHORTAGE notification para sad sa inventory team.
     6. STOCK_ALLOCATED notification RelatedEntityID = requisition
        (para mogana ang click-navigation).
     7. Receiving permission i-tighten sa receiving.manage ra.
     8. Fulfilled requisition auto-mark sa allocated notifs (trigger
        re-emit gikan sa V010 nga may dugang nga type).

   Kani nga migration idempotent (guarded ALTER + CREATE OR ALTER).
   THROW range: 50410-50419.
*/

USE JustMakeOverSalonDB;
GO

/*
   1. SCHEMA — QuantityReceived (partial receive tracking) ug
      OriginRequisitionID (requisition trace sa RepF).
*/
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.REPLENISHMENT_REQUESTS')
      AND name = 'QuantityReceived'
)
    ALTER TABLE dbo.REPLENISHMENT_REQUESTS
        ADD QuantityReceived INT NOT NULL
            CONSTRAINT DF_REPF_QuantityReceived DEFAULT (0);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.REPLENISHMENT_REQUESTS')
      AND name = 'OriginRequisitionID'
)
    ALTER TABLE dbo.REPLENISHMENT_REQUESTS
        ADD OriginRequisitionID INT NULL
            CONSTRAINT FK_REPF_OriginRequisition
            REFERENCES dbo.REQUISITIONS (RequisitionID);
GO

/*
   2. ISSUE STOCK — re-emit gikan sa V003 nga may duha ka dugang:
      a) ang RepF gi-tag ug OriginRequisitionID (trace sa shortage
         source, requisition # sa Inventory RepF table).
      b) ang STOCK_SHORTAGE notif kay moabot na sad sa inventory
         team (inventory.view users), dili na requester ra.
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

    -- Kani nga check kay para masiguro nga active ug existing ang item.
    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50317, 'The item is inactive or was not found.', 1;

    DECLARE @RequestorUserID INT = @ActorUserID;
    DECLARE @RequisitionDetailID INT = NULL;
    DECLARE @RemainingQty INT = @QuantityRequested;

    -- Kani nga block kay para sa approved ReF nga source sa issuance.
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

        -- Kani nga subtraction kay para dili mag-double reservation sa same detail.
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

    -- Kani nga case kay para sa sufficient stock: full reservation lang.
    IF @Available >= @RemainingQty
    BEGIN
        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @RemainingQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        -- Kani nga remarks kay para makita nga issuance reservation kini.
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

            -- Kani nga reservation row kay para sa traceability sa issuance.
            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @RemainingQty, SYSDATETIME(), 'Active');
        END;

        -- Kani nga notification kay para sa requestor: reserved ug ready for delivery.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_RESERVED', 'Stock reserved',
                'Your requested item has been reserved and is ready for delivery.',
                'REQUISITION', @RequisitionID, 0, SYSDATETIME());

        COMMIT TRANSACTION;

        -- Kani nga EXEC kay para sa reorder-point diamond sa Figure 8.A:
        -- pagkahuman sa reservation ug balance update, i-check kung
        -- stock at or below reorder point -> low-stock alert + RepF.
        -- Ang dedup check naa na sa CheckReorderPoint (walay duplicate
        -- RepF samtang open pa ang usaha).
        EXEC usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;

        SELECT 'Reserved' AS Outcome, @RemainingQty AS ReservedQuantity, 0 AS ShortageQuantity, NULL AS RepFID;
        RETURN;
    END;

    -- Kani nga case kay para sa insufficient stock: partial reservation + shortage.
    DECLARE @ShortageQty INT = @RemainingQty - @Available;

    IF @Available > 0
    BEGIN
        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @Available, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        -- Kani nga remarks kay para sa partial reservation sa issuance.
        INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @Available, @Reserved, @Reserved + @Available,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CONCAT('Partial reservation: only ', @Available, ' of ', @RemainingQty,
                       ' unit(s) available. Replenishment request generated.'), SYSDATETIME());

        -- Kani nga reservation row kay para sa partial nga na-reserve lang.
        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @Available, SYSDATETIME(), 'Active');
        END;
    END;

    -- Kani nga RepF kay para sa shortage: to Purchasing/Receiving.
    -- Kani nga OriginRequisitionID kay para sa trace (Requisition #
    -- sa Inventory RepF table).
    DECLARE @NewRepFID INT = NULL;
    IF @ShortageQty > 0
    BEGIN
        INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status, OriginRequisitionID)
        VALUES (@ItemID, @ShortageQty, SYSDATETIME(), 'Pending', @RequisitionID);
        SET @NewRepFID = SCOPE_IDENTITY();
    END;

    IF @RequisitionDetailID IS NOT NULL
    BEGIN
        UPDATE REQUISITION_DETAILS
        SET Status = CASE WHEN @Available > 0 THEN 'Partially Fulfilled' ELSE 'Pending' END
        WHERE RequisitionDetailID = @RequisitionDetailID;
    END;

    -- Kani nga notification kay para sa requester: pending + estimated date.
    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, 7, CAST(SYSDATETIME() AS DATE)));
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT('Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                   CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME());

    -- Kani nga notification kay para sad sa inventory team: kita nila
    -- dayon nga naay shortage nga kinahanglan i-replenish.
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
   3. RECEIVE STOCK — re-emit gikan sa V003 nga may mga fix:
      a) PARTIAL RECEIVE: ang RepF dili dayon ma-'Processed' kung
         kulang pa ang nadawat — QuantityReceived tracking + cap.
      b) Over-receive guard: dili molapas sa remaining needed.
      c) STOCK_ALLOCATED notif RelatedEntityID = requisition.
      d) Permission i-tighten sa receiving.manage ra.
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
    END;

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
    END;

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
        -- for delivery. Kani nga RelatedEntityID kay para mogana ang
        -- click-navigation padulong sa requisition.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_ALLOCATED', 'Stock allocated to your request',
                'Received stock was allocated to your request. It is ready for delivery.',
                'REQUISITION', @ReservationRequisitionID, 0, SYSDATETIME());

        FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;
    END;

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
    END;
END;
GO

/*
   4. RECEIVING PENDING — re-emit gikan sa V004 nga may QuantityReceived
      (para sa remaining display sa pending queue).
*/
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
    ORDER BY f.DateGenerated ASC;
END;
GO

/*
   5. INVENTORY RepF LIST — re-emit gikan sa V003 nga may
      OriginRequisitionID (Requisition # column).
*/
CREATE OR ALTER PROCEDURE dbo.usp_Inventory_GetRepFs
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50326, 'You do not have permission to view replenishment requests.', 1;

    SELECT f.RepFID, f.ItemID, i.ItemName, i.ItemCode, f.QuantityNeeded,
           f.DateGenerated, f.Status, f.OriginRequisitionID
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    ORDER BY CASE WHEN f.Status = 'Pending' THEN 0 ELSE 1 END, f.DateGenerated DESC;
END;
GO

/*
   6. TRIGGERS — allocated-ready notification cycle:
      a) Kung ma-fully-allocated na ang tanang items sa usa ka
         approved requisition (approve o receive-allocation),
         ma-notify ang delivery.view users (Inventory, Manager,
         Admin) — action-required hangtod ma-generate ang AR.
      b) Pag-Generate AR (DELIVERIES INSERT), auto-mark read ang
         tanang REQUISITION_ALLOCATED notifs sa kana nga requisition
         (na-take na ang action).
*/
CREATE OR ALTER TRIGGER dbo.trg_REQUISITION_DETAILS_AllocatedReadyNotify
ON dbo.REQUISITION_DETAILS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, N'REQUISITION_ALLOCATED', N'Requisition ready for delivery',
           CONCAT(N'All items of requisition #', r.RequisitionID,
                  N' are allocated. Generate the acknowledgement receipt in the Delivery module.'),
           N'REQUISITION', r.RequisitionID, 0, SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d ON d.RequisitionDetailID = i.RequisitionDetailID
    INNER JOIN REQUISITIONS r ON r.RequisitionID = i.RequisitionID
    INNER JOIN USERS u
        ON u.IsActive = 1
       AND EXISTS (
            SELECT 1
            FROM ROLE_PERMISSIONS rp
            INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE rp.RoleID = u.RoleID
              AND p.PermissionCode = N'delivery.view'
       )
    WHERE i.Status = N'Approved'
      AND d.Status <> N'Approved'
      AND r.Status = N'Approved'
      AND NOT EXISTS (
            SELECT 1 FROM REQUISITION_DETAILS x
            WHERE x.RequisitionID = r.RequisitionID
              AND x.Status IN (N'Pending', N'Partially Fulfilled')
      )
      AND NOT EXISTS (
            SELECT 1 FROM DELIVERIES y
            WHERE y.RequisitionID = r.RequisitionID
              AND y.Status IN (N'Generated', N'Issued')
      )
      AND NOT EXISTS (
            SELECT 1 FROM NOTIFICATIONS n
            WHERE n.NotificationType = N'REQUISITION_ALLOCATED'
              AND n.RelatedEntityType = N'REQUISITION'
              AND n.RelatedEntityID = r.RequisitionID
      );
END;
GO

CREATE OR ALTER TRIGGER dbo.trg_DELIVERIES_AfterInsert_AutoMarkAllocatedNotifs
ON dbo.DELIVERIES
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga auto-mark kay para sa "action accomplished" principle:
    -- ang Generate AR mao ang action sa allocated-ready notifs, so
    -- mark read na ang tanan sa kana nga requisition.
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType = N'REQUISITION_ALLOCATED'
      AND n.RelatedEntityType = N'REQUISITION'
      AND n.IsRead = 0;
END;
GO

/*
   7. CANCEL NOTIFICATIONS — re-emit sa usp_Requisition_Cancel nga
      may notifications: ang requestor ma-notify kung laing tawo
      (Admin/Manager) ang mo-cancel, ug ang stakeholders (approvers
      + inventory team) ma-notify sa tanang cancellation.
*/
CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Cancel
    @RequisitionID INT,
    @ActorUserID INT,
    @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RequestorUserID INT, @ActorRole NVARCHAR(50);
        SELECT @RequestorUserID = RequestorUserID
        FROM REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved');

        IF @RequestorUserID IS NULL
            THROW 50200, 'Dili makita ang pending o approved nga requisition.', 1;

        SELECT @ActorRole = r.RoleName
        FROM USERS u INNER JOIN ROLES r ON r.RoleID = u.RoleID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1 AND r.IsActive = 1;

        IF @ActorRole IS NULL
            THROW 50201, 'Ang user wala o inactive.', 1;

        IF @ActorUserID <> @RequestorUserID AND @ActorRole NOT IN (N'Admin', N'Manager')
            THROW 50202, 'Dili ka authorized sa pagkansela ani nga requisition.', 1;

        DECLARE @ReservationID INT, @DetailID INT, @Qty INT, @ItemID INT, @OnHand INT;
        DECLARE cancel_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT ir.ReservationID, ir.RequisitionDetailID, ir.QuantityReserved, rd.ItemID
            FROM INVENTORY_RESERVATIONS ir
            INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = ir.RequisitionDetailID
            WHERE rd.RequisitionID = @RequisitionID AND ir.Status = 'Active';

        OPEN cancel_cursor;
        FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @OnHand = QuantityOnHand
            FROM INVENTORY WITH (UPDLOCK, HOLDLOCK)
            WHERE ItemID = @ItemID AND QuantityReserved >= @Qty;

            IF @OnHand IS NULL
                THROW 50203, 'Dili sakto ang reserved quantity sa inventory.', 1;

            UPDATE INVENTORY
            SET QuantityReserved = QuantityReserved - @Qty, LastUpdated = SYSDATETIME()
            WHERE ItemID = @ItemID;

            UPDATE INVENTORY_RESERVATIONS
            SET Status = 'Cancelled'
            WHERE ReservationID = @ReservationID AND Status = 'Active';

            INSERT INTO INVENTORY_LOGS
                (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
            VALUES
                (@ItemID, @ActorUserID, 'Release', 0, @OnHand, @OnHand, 'Reservation', @ReservationID,
                 'This reservation was released due to cancellation.');
            FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;
        END;

        CLOSE cancel_cursor;
        DEALLOCATE cancel_cursor;

        UPDATE REQUISITION_DETAILS
        SET Status = 'Cancelled'
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        UPDATE REQUISITIONS
        SET Status = 'Cancelled', RejectionReason = @Reason
        WHERE RequisitionID = @RequisitionID;

        INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @RequestorUserID, 'REQUISITION_CANCELLED',
                CONCAT('Requisition ID: ', @RequisitionID, '. ', COALESCE(@Reason, 'No additional reason provided.')));

        -- Kani nga notification kay para sa requestor kung laing tawo
        -- (Admin/Manager) ang mo-cancel sa iyang requisition.
        IF @ActorUserID <> @RequestorUserID
        BEGIN
            INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
            VALUES (@RequestorUserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
                    CONCAT('Your requisition #', @RequisitionID,
                           ' was cancelled by ', @ActorRole, '. ',
                           COALESCE(@Reason, '')),
                    'REQUISITION', @RequisitionID, 0, SYSDATETIME());
        END;

        -- Kani nga notification kay para sa stakeholders (approvers +
        -- inventory team): mahibaw-an nila nga gi-cancel ang requisition.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT u.UserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
               CONCAT('Requisition #', @RequisitionID, ' was cancelled. ',
                      COALESCE(@Reason, '')),
               'REQUISITION', @RequisitionID, 0, SYSDATETIME()
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND u.UserID <> @RequestorUserID
          AND (p.PermissionCode = N'requisitions.approve'
               OR p.PermissionCode = N'inventory.view');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'cancel_cursor') >= 0 CLOSE cancel_cursor;
        IF CURSOR_STATUS('local', 'cancel_cursor') >= -1 DEALLOCATE cancel_cursor;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/*
   8. FULFILLED AUTO-MARK — re-emit sa V010 trigger nga may dugang
      nga REQUISITION_ALLOCATED (ang allocated-ready notifs kay
      done na kung ma-fulfill ang requisition).
*/
CREATE OR ALTER TRIGGER dbo.trg_REQUISITIONS_FulfilledAutoMarkNotifications
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType IN (N'REQUISITION_APPROVED', N'STOCK_RESERVED', N'REQUISITION_ALLOCATED')
      AND n.RelatedEntityType = N'REQUISITION'
      AND i.Status = N'Fulfilled'
      AND n.IsRead = 0;
END;
GO
