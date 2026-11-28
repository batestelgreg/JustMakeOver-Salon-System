USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DROP TRIGGER IF EXISTS dbo.trg_PurchaseOrders_NotifyRequisitionRequestor;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_ApprovePO
    @POID INT,
    @ApproverUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.approve'
        )
            THROW 50320, 'Approval permission is required to approve a purchase order.', 1;

        DECLARE @Amount DECIMAL(12,2), @BudgetYear INT, @Status VARCHAR(30), @BudgetAmount DECIMAL(14,2), @Committed DECIMAL(14,2);
        SELECT @Amount = TotalAmount, @BudgetYear = YEAR(DateIssued), @Status = Status
        FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE POID = @POID;

        IF @Amount IS NULL
            THROW 50321, 'The purchase order could not be found.', 1;
        IF @Status <> 'Pending Approval'
            THROW 50322, 'The purchase order (PO) must be in Pending Approval status.', 1;

        DECLARE @POCreatorUserID INT = COALESCE(
            (
                SELECT TOP (1) ds.SignerUserID
                FROM dbo.DOCUMENT_SIGNATURES ds
                WHERE ds.DocumentType = 'PURCHASE_ORDER'
                  AND ds.DocumentID = @POID
                  AND ds.Stage = 'Requested'
                  AND ds.IsActive = 1
                ORDER BY ds.SignatureID DESC
            ),
            (
                SELECT pr.CreatedByUserID
                FROM dbo.PURCHASE_ORDERS po
                INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
                WHERE po.POID = @POID
            )
        );

        IF @POCreatorUserID = @ApproverUserID
            THROW 50326, 'You cannot approve your own purchase order. Another authorized approver must review it.', 1;

        SELECT @BudgetAmount = BudgetAmount
        FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
        WHERE BudgetYear = @BudgetYear AND IsActive = 1;

        IF @BudgetAmount IS NULL
            THROW 50323, 'The approved budget for this year has not been configured yet.', 1;

        SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
        FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered');

        IF @Committed + @Amount > @BudgetAmount
            THROW 50324, 'The purchase order exceeds the remaining annual budget.', 1;

        UPDATE dbo.PURCHASE_ORDERS
        SET Status = 'Approved', ApprovedByUserID = @ApproverUserID
        WHERE POID = @POID AND Status = 'Pending Approval';

        IF @@ROWCOUNT <> 1
            THROW 50325, 'The purchase order could not be updated.', 1;

        UPDATE dbo.PURCHASE_REQUESTS
        SET Status = 'Approved'
        WHERE PRID IN (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID)
           OR PRID = (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID);

        /* PO_APPROVED and PO_PENDING_APPROVAL read-state are handled cleanly
           by dbo.trg_Purchasing_PONotifications (single source of truth). */

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER TRIGGER dbo.trg_Purchasing_PONotifications
ON dbo.PURCHASE_ORDERS
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    /* New PO awaiting approval */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'PO_PENDING_APPROVAL',
        'Purchase order awaiting approval',
        CONCAT
        (
            'PO #',
            i.POID,
            ' is awaiting your review. Open Purchasing to approve or reject it.'
        ),
        'PURCHASE_ORDER',
        i.POID,
        0,
        SYSDATETIME()
    FROM inserted i
    LEFT JOIN deleted d
        ON d.POID = i.POID
    CROSS JOIN dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    WHERE i.Status = 'Pending Approval'
      AND
      (
          d.POID IS NULL
          OR d.Status <> i.Status
      )
      AND u.IsActive = 1
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = N'requisitions.approve'
      )
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = N'purchasing.view'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = u.UserID
            AND n.NotificationType = 'PO_PENDING_APPROVAL'
            AND n.RelatedEntityType = 'PURCHASE_ORDER'
            AND n.RelatedEntityID = i.POID
            AND n.IsRead = 0
      );

    /* Approved PO notification */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'PO_APPROVED',
        'Purchase order approved',
        CONCAT
        (
            'PO #',
            i.POID,
            ' was approved. Open Purchasing to prepare the supplier order.'
        ),
        'PURCHASE_ORDER',
        i.POID,
        0,
        SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d
        ON d.POID = i.POID
       AND d.Status <> i.Status
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = i.PRID
    CROSS JOIN dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    WHERE i.Status = 'Approved'
      AND u.IsActive = 1
      AND
      (
          u.UserID = pr.CreatedByUserID
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p
                  ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode = 'purchasing.manage'
          )
      )
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = 'purchasing.view'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = u.UserID
            AND n.NotificationType = 'PO_APPROVED'
            AND n.RelatedEntityType = 'PURCHASE_ORDER'
            AND n.RelatedEntityID = i.POID
            AND n.IsRead = 0
      );

    /* Rejected PO: notify the originating requestor (hold or revise) */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        rq.RequestorUserID,
        'PO_REJECTED',
        'Purchase order rejected',
        CONCAT
        (
            'The purchase order for requisition #',
            rq.RequisitionID,
            ' was rejected. Purchasing will revise the purchase request. ',
            'Hold, or update your request if the need has changed.'
        ),
        'REQUISITION',
        rq.RequisitionID,
        0,
        SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d
        ON d.POID = i.POID
       AND d.Status <> i.Status
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = i.PRID
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.REQUISITIONS rq
        ON rq.RequisitionID = rr.OriginRequisitionID
    WHERE i.Status = 'Rejected'
      AND rq.RequestorUserID IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = rq.RequestorUserID
            AND n.NotificationType = 'PO_REJECTED'
            AND n.RelatedEntityType = 'REQUISITION'
            AND n.RelatedEntityID = rq.RequisitionID
            AND n.IsRead = 0
      );

    /* Review is complete once the PO leaves Pending Approval */

    UPDATE n
    SET
        IsRead = 1,
        ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i
        ON i.POID = n.RelatedEntityID
    WHERE n.NotificationType = 'PO_PENDING_APPROVAL'
      AND n.RelatedEntityType = 'PURCHASE_ORDER'
      AND i.Status <> 'Pending Approval'
      AND n.IsRead = 0;

    /* Dispatch is complete once the PO is Sent to Supplier, Delivered, or Cancelled */

    UPDATE n
    SET
        IsRead = 1,
        ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i
        ON i.POID = n.RelatedEntityID
    WHERE n.NotificationType = 'PO_APPROVED'
      AND n.RelatedEntityType = 'PURCHASE_ORDER'
      AND i.Status IN ('Sent to Supplier', 'Partially Delivered', 'Delivered', 'Cancelled')
      AND n.IsRead = 0;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_ReceiveCheckedDR
    @ActorUserID INT,
    @DRID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN (N'receiving.manage', N'purchasing.manage')
    )
        THROW 50530, 'Receiving or Purchasing management permission is required.', 1;

    DECLARE
        @LockResult INT,
        @POID INT,
        @RepFID INT,
        @ItemID INT,
        @Accepted INT,
        @Baseline INT,
        @ActualReceived INT,
        @PriorApplied INT,
        @RMID INT,
        @ReceivedForPO INT,
        @Ordered INT,
        @Remarks NVARCHAR(1000);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50502, 'Purchasing is busy. Please try again.', 1;

        SELECT
            @POID = dr.POID,
            @RepFID = pr.RepFID,
            @ItemID = dd.ItemID,
            @Accepted = dd.QuantityAccepted,
            @Baseline = pt.ReceivedBeforeOrder,
            @Ordered = po.QuantityOrdered
        FROM dbo.DELIVERY_RECEIPTS dr WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.PURCHASING_DR_TRACKING dt ON dt.DRID = dr.DRID
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.PURCHASING_PO_TRACKING pt ON pt.POID = po.POID
        WHERE dr.DRID = @DRID
          AND dr.Status <> 'Rejected'
          AND po.Status IN ('Sent to Supplier', 'Partially Delivered');

        IF @Accepted IS NULL OR @Accepted <= 0
            THROW 50531, 'No eligible accepted quantity exists for this checked DR.', 1;

        IF
        (
            SELECT COUNT(*) FROM dbo.DELIVERY_RECEIPT_DETAILS
            WHERE DRID = @DRID
        ) <> 1
            THROW 50531, 'This receiving bridge supports one PO item per DR.', 1;

        IF EXISTS
        (
            SELECT 1 FROM dbo.RECEIVING_MEMOS
            WHERE DRID = @DRID
        )
            THROW 50532, 'This DR already has a Receiving Memo.', 1;

        SELECT @ActualReceived = QuantityReceived
        FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
        WHERE RepFID = @RepFID;

        SELECT @PriorApplied = ISNULL(SUM(rmd.QuantityReceived), 0)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
        INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
        WHERE dr.POID = @POID
          AND rm.InventoryUpdated = 1;

        IF @ActualReceived IS NULL
           OR @ActualReceived <> @Baseline + @PriorApplied
            THROW 50533, 'This replenishment has receipts outside the checked-DR workflow. Reconcile them before receiving this DR.', 1;

        IF @PriorApplied + @Accepted > @Ordered
            THROW 50534, 'Receiving would exceed the PO quantity.', 1;

        SET @Remarks = CONCAT(
            'Accepted supplier delivery: PO #', @POID,
            ', DR #', @DRID, '.'
        );

        INSERT INTO dbo.RECEIVING_MEMOS
            (DRID, ReceivedByUserID, Remarks, InventoryUpdated)
        VALUES
            (@DRID, @ActorUserID, @Remarks, 0);

        SET @RMID = SCOPE_IDENTITY();

        INSERT INTO dbo.RECEIVING_MEMO_DETAILS
            (RMID, ItemID, QuantityReceived)
        VALUES
            (@RMID, @ItemID, @Accepted);

        EXEC dbo.usp_Inventory_ReceiveStock
            @ActorUserID = @ActorUserID,
            @ItemID = @ItemID,
            @QuantityReceived = @Accepted,
            @RepFID = @RepFID,
            @Remarks = @Remarks;

        UPDATE dbo.RECEIVING_MEMOS
        SET InventoryUpdated = 1
        WHERE RMID = @RMID;

        SET @ReceivedForPO = @PriorApplied + @Accepted;

        UPDATE dbo.PURCHASE_ORDERS
        SET Status = CASE
            WHEN @ReceivedForPO >= QuantityOrdered THEN 'Delivered'
            ELSE 'Partially Delivered'
        END
        WHERE POID = @POID;

        IF @ReceivedForPO >= @Ordered
        BEGIN
            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Closed'
            WHERE PRID =
                (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID);
        END;

        UPDATE dbo.NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationType = 'PURCHASE_DELIVERY'
          AND RelatedEntityType = 'DELIVERY_RECEIPT'
          AND RelatedEntityID = @DRID
          AND IsRead = 0;

        /* Notify Purchasing that checked supplier stock has been received into inventory */
        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID,
            IsRead,
            CreatedAt
        )
        SELECT DISTINCT
            u.UserID,
            'PO_RECEIVED',
            'Supplier delivery stocked into inventory',
            CONCAT(
                'PO #', @POID,
                ' (DR #', @DRID, ', ', @Accepted, ' unit(s)) has been received via RM #', @RMID, '.'),
            'PURCHASE_ORDER',
            @POID,
            0,
            SYSDATETIME()
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND p.PermissionCode = N'purchasing.manage';

        INSERT INTO dbo.USER_AUDIT_LOGS
            (ActorUserID, TargetUserID, ActionType, Description)
        VALUES
            (@ActorUserID, @ActorUserID, 'PURCHASE_DR_RECEIVED',
             CONCAT('DR #', @DRID, ' received through RM #', @RMID,
                    '. Quantity: ', @Accepted, '.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO


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
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND (
              p.PermissionCode = N'inventory.update'
              OR (@RequisitionID IS NOT NULL AND p.PermissionCode = N'requisitions.approve')
          )
    )
        THROW 50316, 'You do not have permission to issue stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50317, 'The item is inactive or was not found.', 1;

    DECLARE @RequestorUserID INT = @ActorUserID;
    DECLARE @RequisitionDetailID INT = NULL;
    DECLARE @RemainingQty INT = @QuantityRequested;

    IF @RequisitionID IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.REQUISITIONS WHERE RequisitionID = @RequisitionID AND Status = 'Approved')
            THROW 50318, 'Only an approved requisition can be issued stock.', 1;

        SELECT @RequestorUserID = r.RequestorUserID
        FROM dbo.REQUISITIONS r
        WHERE r.RequisitionID = @RequisitionID;

        SELECT TOP (1) @RequisitionDetailID = rd.RequisitionDetailID,
                       @RemainingQty = ISNULL(rd.QuantityApproved, rd.QuantityRequested)
        FROM dbo.REQUISITION_DETAILS rd
        WHERE rd.RequisitionID = @RequisitionID
          AND rd.ItemID = @ItemID
          AND rd.Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        IF @RequisitionDetailID IS NULL
            THROW 50319, 'The requisition does not include this item or it is already fulfilled.', 1;

        DECLARE @AlreadyReserved INT = ISNULL((
            SELECT SUM(r.QuantityReserved)
            FROM dbo.INVENTORY_RESERVATIONS r
            WHERE r.RequisitionDetailID = @RequisitionDetailID AND r.Status = 'Active'
        ), 0);

        SET @RemainingQty = @RemainingQty - @AlreadyReserved;

        IF @RemainingQty <= 0
            THROW 50328, 'This requisition item is already fully reserved.', 1;
    END;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM dbo.INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM dbo.INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Available INT = @OnHand - @Reserved;

    IF @Available >= @RemainingQty
    BEGIN
        UPDATE dbo.INVENTORY
        SET QuantityReserved = QuantityReserved + @RemainingQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @RemainingQty, @Reserved, @Reserved + @RemainingQty,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CASE WHEN @RequisitionID IS NULL
                     THEN CONCAT('Stock reserved for issuance: ', @RemainingQty, ' unit(s).')
                     ELSE N'Stock reserved for approved requisition.'
                END, SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            UPDATE dbo.REQUISITION_DETAILS
            SET Status = 'Approved'
            WHERE RequisitionDetailID = @RequisitionDetailID;

            INSERT INTO dbo.INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @RemainingQty, SYSDATETIME(), 'Active');
        END;

        INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_RESERVED', 'Stock reserved',
                'Your requested item has been reserved and is ready for delivery.',
                'REQUISITION', @RequisitionID, 0, SYSDATETIME());

        COMMIT TRANSACTION;

        EXEC dbo.usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;

        SELECT 'Reserved' AS Outcome, @RemainingQty AS ReservedQuantity, 0 AS ShortageQuantity, NULL AS RepFID;
        RETURN;
    END;

    DECLARE @ShortageQty INT = @RemainingQty - @Available;

    IF @Available > 0
    BEGIN
        UPDATE dbo.INVENTORY
        SET QuantityReserved = QuantityReserved + @Available, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @Available, @Reserved, @Reserved + @Available,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CONCAT('Partial reservation: only ', @Available, ' of ', @RemainingQty,
                       ' unit(s) available. Replenishment request generated.'), SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            INSERT INTO dbo.INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @Available, SYSDATETIME(), 'Active');
        END;
    END;

    DECLARE @NewRepFID INT = NULL;

    IF @ShortageQty > 0
    BEGIN
        SELECT TOP (1) @NewRepFID = rr.RepFID
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.ItemID = @ItemID
          AND rr.Status = 'Pending'
          AND (rr.OriginRequisitionID IS NULL OR rr.OriginRequisitionID = @RequisitionID)
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID
          )
        ORDER BY rr.RepFID;

        IF @NewRepFID IS NOT NULL
        BEGIN
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET QuantityNeeded = QuantityNeeded + @ShortageQty,
                OriginRequisitionID = COALESCE(OriginRequisitionID, @RequisitionID)
            WHERE RepFID = @NewRepFID;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status, OriginRequisitionID)
            VALUES (@ItemID, @ShortageQty, SYSDATETIME(), 'Pending', @RequisitionID);
            SET @NewRepFID = SCOPE_IDENTITY();
        END;
    END;

    IF @RequisitionDetailID IS NOT NULL
    BEGIN
        UPDATE dbo.REQUISITION_DETAILS
        SET Status = CASE WHEN @Available > 0 THEN 'Partially Fulfilled' ELSE 'Pending' END
        WHERE RequisitionDetailID = @RequisitionDetailID;
    END;

    DECLARE @RestockDays INT = ISNULL(
        NULLIF((SELECT TOP (1) TRY_CONVERT(INT, SettingValue) FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'DefaultRestockDays'), 0),
        7);
    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, @RestockDays, CAST(SYSDATETIME() AS DATE)));

    /* Requestor's shortage notice links directly to their Requisition so clicking highlights their RF row. */
    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT(
                CASE WHEN @RequisitionID IS NOT NULL
                     THEN CONCAT('Requisition #', @RequisitionID, ': ')
                     ELSE ''
                END,
                'Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            CASE WHEN @RequisitionID IS NOT NULL THEN 'REQUISITION' ELSE 'REPLENISHMENT_REQUEST' END,
            COALESCE(@RequisitionID, @NewRepFID),
            0, SYSDATETIME());

    /* Replenishment alert links to RepF for Purchasing Staff and Inventory Staff. */
    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'STOCK_SHORTAGE', 'Stock shortage needs replenishment',
           CONCAT('A shortage of ', @ShortageQty, ' unit(s) was noted on an item (',
                  i.ItemName, '). A replenishment request was generated.'),
           'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    INNER JOIN dbo.ITEMS i ON i.ItemID = @ItemID
    WHERE u.IsActive = 1
      AND p.PermissionCode IN (N'purchasing.view', N'inventory.update')
      AND u.UserID <> @RequestorUserID;

    COMMIT TRANSACTION;
    SELECT 'Shortage' AS Outcome, @Available AS ReservedQuantity, @ShortageQty AS ShortageQuantity, @NewRepFID AS RepFID;
END;
GO


CREATE OR ALTER TRIGGER dbo.trg_REQUISITION_DETAILS_AllocatedReadyNotify
ON dbo.REQUISITION_DETAILS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, N'REQUISITION_ALLOCATED', N'Requisition ready for delivery',
           CONCAT(N'All items of requisition #', r.RequisitionID,
                  N' are allocated. Generate the acknowledgement receipt in the Delivery module.'),
           N'REQUISITION', r.RequisitionID, 0, SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d ON d.RequisitionDetailID = i.RequisitionDetailID
    INNER JOIN dbo.REQUISITIONS r ON r.RequisitionID = i.RequisitionID
    INNER JOIN dbo.USERS u
        ON u.IsActive = 1
       AND u.UserID <> r.RequestorUserID
       AND EXISTS (
            SELECT 1
            FROM dbo.ROLES ro
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = ro.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE ro.RoleID = u.RoleID
              AND ro.IsActive = 1
              AND p.PermissionCode = N'delivery.manage'
       )
    WHERE i.Status = N'Approved'
      AND d.Status <> N'Approved'
      AND r.Status = N'Approved'
      AND NOT EXISTS (
            SELECT 1 FROM dbo.REQUISITION_DETAILS x
            WHERE x.RequisitionID = r.RequisitionID
              AND x.Status IN (N'Pending', N'Partially Fulfilled')
      )
      AND NOT EXISTS (
            SELECT 1 FROM dbo.DELIVERIES y
            WHERE y.RequisitionID = r.RequisitionID
              AND y.Status IN (N'Generated', N'Issued')
      )
      AND NOT EXISTS (
            SELECT 1 FROM dbo.NOTIFICATIONS n
            WHERE n.RecipientUserID = u.UserID
              AND n.NotificationType = N'REQUISITION_ALLOCATED'
              AND n.RelatedEntityType = N'REQUISITION'
              AND n.RelatedEntityID = r.RequisitionID
              AND n.IsRead = 0
      );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_MarkIssued
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can issue delivery items.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Generated'
    )
        THROW 50406,
            'Only a generated acknowledgement receipt can be marked as issued.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50420,
            'A signature is required before issuing the items.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50421,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50422,
            'The signature image is too large.',
            1;

    BEGIN TRANSACTION;

    DECLARE @RequestorUserID INT;
    DECLARE @ARCode VARCHAR(30);
    DECLARE @RequisitionID INT;

    SELECT
        @RequestorUserID = d.RequestorUserID,
        @ARCode = d.ARCode,
        @RequisitionID = d.RequisitionID
    FROM dbo.DELIVERIES d
    WHERE d.DeliveryID = @DeliveryID;

    UPDATE dbo.DELIVERIES
    SET Status = N'Issued',
        IssuedByUserID = @ActorUserID,
        IssuedSignatureData = @Signature,
        IssuedDate = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Issued',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    /* Notify the requestor that their items have been issued for inspection and e-signature */
    IF @RequestorUserID IS NOT NULL AND @RequestorUserID <> @ActorUserID
    BEGIN
        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID,
            IsRead,
            CreatedAt
        )
        VALUES
        (
            @RequestorUserID,
            'DELIVERY_ISSUED',
            'Items issued for delivery',
            CONCAT(
                'Acknowledgement receipt ',
                ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
                ' for requisition #',
                @RequisitionID,
                ' has been issued. Inspect your items and e-sign in Delivery.'
            ),
            'DELIVERY',
            @DeliveryID,
            0,
            SYSDATETIME()
        );
    END;

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        ISNULL(@RequestorUserID, @ActorUserID),
        'DELIVERY_ISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' marked as issued with an inventory signature.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_NoteDiscrepancy
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanAcknowledge
       (
           @ActorUserID,
           @DeliveryID
       ) = 0
        THROW 50401,
            'Only the Requestor of this receipt or an Admin can acknowledge it.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
        THROW 50407,
            'A discrepancy note is required.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50408,
            'A discrepancy can only be noted on an issued acknowledgement receipt.',
            1;

    DECLARE @ARCode VARCHAR(30) = (SELECT ARCode FROM dbo.DELIVERIES WHERE DeliveryID = @DeliveryID);

    UPDATE dbo.DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes)),
        DiscrepancyResolvedAt = NULL,
        CorrectedAt = NULL,
        CorrectedByUserID = NULL,
        CorrectionNotes = NULL
    WHERE DeliveryID = @DeliveryID;

    /* Notify delivery.manage team (Inventory Staff / Admin), not Purchasing Staff */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'DELIVERY_DISCREPANCY',
        'Delivery discrepancy noted',
        CONCAT(
            'A discrepancy was noted on ',
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            '. The item may need replacement or record correction.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1
      AND u.UserID <> @ActorUserID
      AND p.PermissionCode = N'delivery.manage';

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        @ActorUserID,
        'DELIVERY_DISCREPANCY',
        CONCAT
        (
            'Discrepancy noted on acknowledgement receipt #',
            @DeliveryID,
            '.'
        )
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Reissue
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can re-issue acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50413,
            'Only an issued acknowledgement receipt can be re-issued.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50414,
            'Note the discrepancy first before re-issuing the acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND CorrectedAt IS NOT NULL
    )
        THROW 50418,
            'Record the item replacement or record correction before re-issuing the acknowledgement receipt.',
            1;

    DECLARE @RequisitionID INT;
    DECLARE @RequestorUserID INT;
    DECLARE @ARCode VARCHAR(30);

    SELECT
        @RequisitionID = RequisitionID,
        @RequestorUserID = RequestorUserID,
        @ARCode = ARCode
    FROM dbo.DELIVERIES
    WHERE DeliveryID = @DeliveryID;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50415,
            'Correct the requisition allocation before re-issuing the acknowledgement receipt.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.DELIVERIES
    SET Status = N'Generated',
        IssuedDate = NULL,
        IssuedByUserID = NULL,
        IssuedSignatureData = NULL,
        SignedByUserID = NULL,
        SignedDate = NULL,
        DiscrepancyResolvedAt = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        ISNULL(@RequestorUserID, @ActorUserID),
        'DELIVERY_REISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' returned to Generated for re-issue after a discrepancy; requisition #',
            @RequisitionID,
            '.'
        )
    );

    /* Notify delivery.manage team (when re-issuance needs re-issuing) and requestor */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        targets.UserID,
        'DELIVERY_REISSUED',
        'Acknowledgement receipt re-issued',
        CONCAT
        (
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            ' was returned for correction and is ready to be issued again.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM
    (
        SELECT u.UserID
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND p.PermissionCode = N'delivery.manage'
        UNION
        SELECT @RequestorUserID
        WHERE @RequestorUserID IS NOT NULL
          AND @RequestorUserID <> @ActorUserID
    ) targets;

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Complete
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanAcknowledge
       (
           @ActorUserID,
           @DeliveryID
       ) = 0
        THROW 50401,
            'Only the Requestor of this receipt or an Admin can acknowledge it.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50409,
            'Only an issued acknowledgement receipt can be signed and completed.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND IssuedByUserID IS NOT NULL
          AND NULLIF
              (
                  LTRIM(RTRIM(IssuedSignatureData)),
                  N''
              ) IS NOT NULL
    )
        THROW 50423,
            'The items must be issued with an inventory signature before the acknowledgement receipt can be completed.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50410,
            'A signature is required before completing the delivery.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50411,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50412,
            'The signature image is too large.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50417,
            'A discrepancy is still open. Re-issue the acknowledgement receipt after the item is replaced or the record is corrected.',
            1;

    DECLARE
        @RequisitionID INT,
        @RequestorUserID INT,
        @IssuedByUserID INT,
        @ARCode VARCHAR(30);

    SELECT
        @RequisitionID = RequisitionID,
        @RequestorUserID = RequestorUserID,
        @IssuedByUserID = IssuedByUserID,
        @ARCode = ARCode
    FROM dbo.DELIVERIES
    WHERE DeliveryID = @DeliveryID;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50404,
            'All requisition items must be fully allocated before completing the delivery.',
            1;

    BEGIN TRANSACTION;

    DECLARE @ItemID INT;
    DECLARE @DetailID INT;
    DECLARE @Quantity INT;
    DECLARE @OnHand INT;
    DECLARE @Reserved INT;
    DECLARE @ActiveReserved INT;

    DECLARE delivery_items CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            di.ItemID,
            di.RequisitionDetailID,
            di.Quantity
        FROM dbo.DELIVERY_ITEMS di
        WHERE di.DeliveryID = @DeliveryID;

    OPEN delivery_items;

    FETCH NEXT FROM delivery_items
    INTO @ItemID, @DetailID, @Quantity;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @OnHand = QuantityOnHand,
            @Reserved = QuantityReserved
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        IF @OnHand IS NULL
            THROW 50405,
                'No stock record exists for a delivery item.',
                1;

        SET @ActiveReserved = ISNULL
        (
            (
                SELECT SUM(r.QuantityReserved)
                FROM dbo.INVENTORY_RESERVATIONS r
                WHERE r.RequisitionDetailID = @DetailID
                  AND r.Status = N'Active'
            ),
            0
        );

        IF @ActiveReserved < @Quantity
           OR @Reserved < @Quantity
           OR @OnHand < @Quantity
            THROW 50405,
                'The reserved stock for a delivery item is no longer available. Correct the record and try again.',
                1;

        UPDATE dbo.INVENTORY
        SET QuantityOnHand = QuantityOnHand - @Quantity,
            QuantityReserved = QuantityReserved - @Quantity,
            LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        SELECT @OnHand = QuantityOnHand
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS
        (
            ItemID,
            UserID,
            TransactionType,
            QuantityChange,
            PreviousQuantity,
            NewQuantity,
            ReferenceType,
            ReferenceID,
            Remarks,
            TransactionDate
        )
        VALUES
        (
            @ItemID,
            @ActorUserID,
            N'Stock Out',
            -@Quantity,
            @OnHand + @Quantity,
            @OnHand,
            N'DELIVERY',
            @DeliveryID,
            N'Items issued and delivered (acknowledgement receipt).',
            SYSDATETIME()
        );

        UPDATE dbo.INVENTORY_RESERVATIONS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID
          AND Status = N'Active';

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID;

        FETCH NEXT FROM delivery_items
        INTO @ItemID, @DetailID, @Quantity;
    END;

    CLOSE delivery_items;
    DEALLOCATE delivery_items;

    UPDATE dbo.DELIVERIES
    SET Status = N'Completed',
        SignedByUserID = @ActorUserID,
        SignedDate = SYSDATETIME(),
        ESignatureData = @Signature
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Received',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    UPDATE dbo.REQUISITIONS
    SET Status = N'Fulfilled'
    WHERE RequisitionID = @RequisitionID;

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    VALUES
    (
        @RequestorUserID,
        'REQUISITION_FULFILLED',
        'Requisition fulfilled',
        'Your requested items have been delivered and your requisition is now fulfilled.',
        'REQUISITION',
        @RequisitionID,
        0,
        SYSDATETIME()
    );

    /* Notify the issuer / delivery managers that the requestor signed and completed the AR */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        targets.UserID,
        'DELIVERY_COMPLETED',
        'Acknowledgement receipt completed',
        CONCAT(
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            ' for requisition #',
            @RequisitionID,
            ' was signed and completed.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM
    (
        SELECT u.UserID
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
        UNION
        SELECT @IssuedByUserID
        WHERE @IssuedByUserID IS NOT NULL
    ) targets
    WHERE targets.UserID <> @ActorUserID;

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        @RequestorUserID,
        'DELIVERY_COMPLETED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' signed electronically; requisition #',
            @RequisitionID,
            ' fulfilled.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER TRIGGER dbo.trg_DELIVERIES_AutoMarkNotifications
ON dbo.DELIVERIES
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    /* 1. Clear discrepancy alerts once AR is re-issued (Generated) or Completed */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_DISCREPANCY'
      AND n.RelatedEntityType = N'DELIVERY'
      AND i.Status IN (N'Generated', N'Completed')
      AND n.IsRead = 0;

    /* 2. Clear re-issue alert once AR is Issued again or Completed */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_REISSUED'
      AND n.RelatedEntityType = N'DELIVERY'
      AND i.Status IN (N'Issued', N'Completed')
      AND n.IsRead = 0;

    /* 3. Clear issued alert once AR is Completed or an open discrepancy is noted */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_ISSUED'
      AND n.RelatedEntityType = N'DELIVERY'
      AND (
          i.Status = N'Completed'
          OR (NULLIF(LTRIM(RTRIM(i.DiscrepancyNotes)), N'') IS NOT NULL AND i.DiscrepancyResolvedAt IS NULL)
      )
      AND n.IsRead = 0;
END;
GO


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
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType IN (
        N'REQUISITION_APPROVED',
        N'STOCK_RESERVED',
        N'STOCK_ALLOCATED',
        N'STOCK_SHORTAGE',
        N'REQUISITION_ALLOCATED'
    )
      AND n.RelatedEntityType = N'REQUISITION'
      AND i.Status IN (N'Fulfilled', N'Cancelled')
      AND n.IsRead = 0;
END;
GO

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

        DECLARE
            @RequestorUserID INT,
            @ActorRole NVARCHAR(50),
            @CanApprove BIT = 0;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved');

        IF @RequestorUserID IS NULL
            THROW 50200, 'The pending or approved requisition could not be found.', 1;

        SELECT
            @ActorRole = r.RoleName,
            @CanApprove = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END)
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        LEFT JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        LEFT JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
        GROUP BY r.RoleName;

        IF @ActorRole IS NULL
            THROW 50201, 'The user account was not found or is inactive.', 1;

        IF @ActorUserID <> @RequestorUserID AND ISNULL(@CanApprove, 0) = 0
            THROW 50202, 'You are not authorized to cancel this requisition.', 1;

        DECLARE @ReservationID INT, @DetailID INT, @Qty INT, @ItemID INT, @OnHand INT;
        DECLARE cancel_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT ir.ReservationID, ir.RequisitionDetailID, ir.QuantityReserved, rd.ItemID
            FROM dbo.INVENTORY_RESERVATIONS ir
            INNER JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionDetailID = ir.RequisitionDetailID
            WHERE rd.RequisitionID = @RequisitionID AND ir.Status = 'Active';

        OPEN cancel_cursor;
        FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @OnHand = QuantityOnHand
            FROM dbo.INVENTORY WITH (UPDLOCK, HOLDLOCK)
            WHERE ItemID = @ItemID AND QuantityReserved >= @Qty;

            IF @OnHand IS NULL
                THROW 50203, 'The reserved quantity in inventory is inconsistent.', 1;

            UPDATE dbo.INVENTORY
            SET QuantityReserved = QuantityReserved - @Qty, LastUpdated = SYSDATETIME()
            WHERE ItemID = @ItemID;

            UPDATE dbo.INVENTORY_RESERVATIONS
            SET Status = 'Cancelled'
            WHERE ReservationID = @ReservationID AND Status = 'Active';

            INSERT INTO dbo.INVENTORY_LOGS
                (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
            VALUES
                (@ItemID, @ActorUserID, 'Release', 0, @OnHand, @OnHand, 'Reservation', @ReservationID,
                 'This reservation was released due to cancellation.');
            FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;
        END;

        CLOSE cancel_cursor;
        DEALLOCATE cancel_cursor;

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = 'Cancelled'
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        UPDATE dbo.REQUISITIONS
        SET Status = 'Cancelled', RejectionReason = @Reason
        WHERE RequisitionID = @RequisitionID;

        UPDATE pr
        SET Status = 'Cancelled'
        FROM dbo.PURCHASE_REQUESTS pr
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        WHERE rr.OriginRequisitionID = @RequisitionID
          AND pr.Status IN ('Open', 'Pending Approval', 'Approved', 'Rejected')
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PURCHASE_ORDERS po
              WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                AND
                (
                    po.PRID = pr.PRID
                    OR EXISTS
                    (
                        SELECT 1 FROM dbo.PO_PR_Mapping m
                        WHERE m.POID = po.POID AND m.PRID = pr.PRID
                    )
                )
          );

        UPDATE dbo.REPLENISHMENT_REQUESTS
        SET Status = 'Cancelled'
        WHERE OriginRequisitionID = @RequisitionID
          AND Status = 'Pending';

        UPDATE dbo.NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationType IN (N'REQUISITION_ALLOCATED', N'STOCK_ALLOCATED', N'STOCK_SHORTAGE')
          AND RelatedEntityType = N'REQUISITION'
          AND RelatedEntityID = @RequisitionID
          AND IsRead = 0;

        INSERT INTO dbo.USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @RequestorUserID, 'REQUISITION_CANCELLED',
                CONCAT('Requisition ID: ', @RequisitionID, '. ', COALESCE(@Reason, 'No additional reason provided.')));

        IF @ActorUserID <> @RequestorUserID
        BEGIN
            INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
            VALUES (@RequestorUserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
                    CONCAT('Your requisition #', @RequisitionID,
                           ' was cancelled by ', @ActorRole, '. ',
                           COALESCE(@Reason, '')),
                    'REQUISITION', @RequisitionID, 0, SYSDATETIME());
        END;

        /* Notify approvers and inventory staff (who have requisitions.view), excluding Purchasing Staff */
        INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT u.UserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
               CONCAT('Requisition #', @RequisitionID, ' was cancelled. ',
                      COALESCE(@Reason, '')),
               'REQUISITION', @RequisitionID, 0, SYSDATETIME()
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND u.UserID <> @RequestorUserID
          AND EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode IN (N'requisitions.approve', N'inventory.update')
          )
          AND EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode = N'requisitions.view'
          );

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
