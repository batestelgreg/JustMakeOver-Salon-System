USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO


DELETE rp
FROM dbo.ROLE_PERMISSIONS rp
INNER JOIN dbo.ROLES r ON r.RoleID = rp.RoleID
INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
WHERE (r.RoleName = N'Manager' AND p.PermissionCode = N'inventory.update')
   OR (r.RoleName = N'Purchasing Staff' AND p.PermissionCode IN (N'delivery.view', N'requisitions.view'))
   OR (r.RoleName = N'Staff' AND p.PermissionCode = N'inventory.view');
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

    -- Manual stock issuance requires inventory.update; requisition approval
    -- auto-reservation also permits requisitions.approve without giving
    -- Managers direct inventory.update access.
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

    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT('Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                   CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME());

    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'STOCK_SHORTAGE', 'Stock shortage needs replenishment',
           CONCAT('A shortage of ', @ShortageQty, ' unit(s) was noted on an item (',
                  i.ItemName, '). A replenishment request was generated.'),
           'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    INNER JOIN dbo.ITEMS i ON i.ItemID = @ItemID
    WHERE u.IsActive = 1
      AND p.PermissionCode = N'inventory.view'
      AND u.UserID <> @RequestorUserID;

    COMMIT TRANSACTION;
    SELECT 'Shortage' AS Outcome, @Available AS ReservedQuantity, @ShortageQty AS ShortageQuantity, @NewRepFID AS RepFID;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Approve
    @RequisitionID INT,
    @ApproverUserID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RequestorUserID INT;
    DECLARE @ItemID INT;
    DECLARE @QuantityRequested INT;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.approve'
        )
        BEGIN
            THROW 50001, 'You do not have permission to approve requisitions.', 1;
        END;

        IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
            THROW 50004,
                'A signature is required before approving the requisition.',
                1;

        IF @Signature NOT LIKE N'data:image/%'
            THROW 50005,
                'The signature image is not valid.',
                1;

        IF LEN(@Signature) > 2000000
            THROW 50006,
                'The signature image is too large.',
                1;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50002, 'Requisition not found or is no longer pending.', 1;
        END;

        IF @RequestorUserID = @ApproverUserID
        BEGIN
            THROW 50007, 'You cannot approve your own requisition. Another authorized approver must review it.', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
        )
        BEGIN
            THROW 50003, 'This requisition has no items.', 1;
        END;

        UPDATE dbo.REQUISITIONS
        SET
            Status = 'Approved',
            DepartmentHeadUserID = @ApproverUserID,
            ApprovalSignatureData = @Signature,
            ApprovedDate = SYSDATETIME()
        WHERE RequisitionID = @RequisitionID;

        UPDATE dbo.REQUISITION_DETAILS
        SET
            QuantityApproved = QuantityRequested
        WHERE RequisitionID = @RequisitionID;

        DECLARE requisition_items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemID, QuantityRequested
            FROM dbo.REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
            ORDER BY RequisitionDetailID;

        OPEN requisition_items;

        FETCH NEXT FROM requisition_items
        INTO @ItemID, @QuantityRequested;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Inventory_IssueStock
                @ActorUserID = @ApproverUserID,
                @ItemID = @ItemID,
                @QuantityRequested = @QuantityRequested,
                @RequisitionID = @RequisitionID;

            FETCH NEXT FROM requisition_items
            INTO @ItemID, @QuantityRequested;
        END;

        CLOSE requisition_items;
        DEALLOCATE requisition_items;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID,
            TargetUserID,
            ActionType,
            Description
        )
        VALUES
        (
            @ApproverUserID,
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Approved requisition #' + CAST(@RequisitionID AS VARCHAR(20))
        );

        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID
        )
        VALUES
        (
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Requisition Approved',
            'Your requisition #' + CAST(@RequisitionID AS VARCHAR(20)) + ' has been approved.',
            'REQUISITION',
            @RequisitionID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'requisition_items') >= 0
            CLOSE requisition_items;

        IF CURSOR_STATUS('local', 'requisition_items') >= -1
            DEALLOCATE requisition_items;

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Reject
    @RequisitionID INT,
    @RejectorUserID INT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RequestorUserID INT;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @RejectorUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.reject'
        )
        BEGIN
            THROW 50004, 'You do not have permission to reject requisitions.', 1;
        END;

        IF @Reason IS NULL OR LEN(LTRIM(RTRIM(@Reason))) = 0
        BEGIN
            THROW 50005, 'A rejection reason is required.', 1;
        END;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50006, 'Requisition not found or is no longer pending.', 1;
        END;

        IF @RequestorUserID = @RejectorUserID
        BEGIN
            THROW 50008, 'You cannot reject your own requisition. Another authorized approver must review it.', 1;
        END;

        UPDATE dbo.REQUISITIONS
        SET
            Status = 'Rejected',
            RejectionReason = @Reason,
            DepartmentHeadUserID = @RejectorUserID
        WHERE RequisitionID = @RequisitionID;

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = 'Rejected'
        WHERE RequisitionID = @RequisitionID;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID,
            TargetUserID,
            ActionType,
            Description
        )
        VALUES
        (
            @RejectorUserID,
            @RequestorUserID,
            'REQUISITION_REJECTED',
            'Rejected requisition #' + CAST(@RequisitionID AS VARCHAR(20))
        );

        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID
        )
        VALUES
        (
            @RequestorUserID,
            'REQUISITION_REJECTED',
            'Requisition Rejected',
            'Your requisition #' + CAST(@RequisitionID AS VARCHAR(20))
                + ' was rejected. Reason: ' + @Reason,
            'REQUISITION',
            @RequisitionID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_DeliveryCanManage
(
    @ActorUserID INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Allowed BIT = 0;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
           AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = r.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    )
        SET @Allowed = 1;

    RETURN @Allowed;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_SetBudget
    @BudgetYear INT,
    @BudgetAmount DECIMAL(14,2),
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @BudgetYear NOT BETWEEN 2000 AND 2100 OR @BudgetAmount < 0
        THROW 50310, 'The budget year or amount is invalid.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50311, 'Settings management permission is required to configure the purchasing budget.', 1;

    IF EXISTS (
        SELECT 1 FROM dbo.PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    ) AND @BudgetAmount < (
        SELECT ISNULL(SUM(TotalAmount), 0) FROM dbo.PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    )
        THROW 50312, 'The budget cannot be set below the total committed purchase orders.', 1;

    MERGE dbo.PURCHASE_BUDGETS AS target
    USING (SELECT @BudgetYear AS BudgetYear) AS source
       ON target.BudgetYear = source.BudgetYear
    WHEN MATCHED THEN UPDATE SET BudgetAmount = @BudgetAmount, IsActive = 1, UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT (BudgetYear, BudgetAmount, IsActive, CreatedByUserID)
         VALUES (@BudgetYear, @BudgetAmount, 1, @ActorUserID);
END;
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

        INSERT INTO dbo.NOTIFICATIONS
            (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT
            pr.CreatedByUserID, 'PO_APPROVED', 'Purchase order approved',
            CONCAT('PO #', @POID, ' for PR #', pr.PRID,
                   ' was approved. Send it to the supplier when ready.'),
            'PURCHASE_ORDER', @POID, 0, SYSDATETIME()
        FROM dbo.PURCHASE_REQUESTS pr
        WHERE pr.CreatedByUserID IS NOT NULL
          AND
          (
              pr.PRID = (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID)
              OR pr.PRID IN (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID)
          );

        UPDATE dbo.NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationType = 'PO_PENDING_APPROVAL'
          AND RelatedEntityType = 'PURCHASE_ORDER'
          AND RelatedEntityID = @POID
          AND IsRead = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_Action
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@Payload) <> 1
        THROW 50500, 'Invalid purchasing request.', 1;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;
    DECLARE @Admin BIT = 0;

    SELECT
        @Manage = MAX(CASE WHEN p.PermissionCode = N'purchasing.manage' THEN 1 ELSE 0 END),
        @Approve = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END),
        @Admin = MAX(CASE WHEN p.PermissionCode = N'settings.manage' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SET @Manage = ISNULL(@Manage, 0);
    SET @Approve = ISNULL(@Approve, 0);
    SET @Admin = ISNULL(@Admin, 0);

    IF @Action IN ('ApprovePO', 'RejectPO')
    BEGIN
        IF @Approve = 0
            THROW 50501,
                'Approval permission is required to decide a PO.',
                1;
    END
    ELSE IF @Action = 'SetBudget'
    BEGIN
        IF @Admin = 0
            THROW 50501,
                'Settings management permission is required to configure the budget.',
                1;
    END
    ELSE IF @Manage = 0
        THROW 50501,
            'Purchasing management permission is required.',
            1;

    DECLARE
        @PRID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID')),
        @RepFID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.repFID')),
        @POID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.poID')),
        @SupplierID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.supplierID')),
        @FollowupID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.followupID')),
        @DRID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.drID')),
        @Year INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.year')),
        @ExpectedDate DATE =
            TRY_CONVERT(DATE, JSON_VALUE(@Payload, '$.expectedDate')),
        @PriceRaw DECIMAL(20,6) =
            TRY_CONVERT(DECIMAL(20,6), JSON_VALUE(@Payload, '$.price')),
        @AmountRaw DECIMAL(20,6) =
            TRY_CONVERT(DECIMAL(20,6), JSON_VALUE(@Payload, '$.amount')),
        @Delivered INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.delivered')),
        @Accepted INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.accepted')),
        @Rejected INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.rejected'));

    DECLARE @NotesInput NVARCHAR(4000) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@Payload, '$.notes'))), '');

    DECLARE @DRInput NVARCHAR(4000) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@Payload, '$.drNumber'))), '');

    IF LEN(@NotesInput) > 1000
        THROW 50500,
            'Notes must be 1000 characters or fewer.',
            1;

    IF LEN(@DRInput) > 100
        THROW 50500,
            'The supplier DR number must be 100 characters or fewer.',
            1;

    DECLARE @Notes NVARCHAR(1000) = @NotesInput;
    DECLARE @DRNumber NVARCHAR(100) = @DRInput;

    DECLARE
        @ResultID INT,
        @Message NVARCHAR(300) = N'Purchasing action completed.',
        @LockResult INT,
        @Status VARCHAR(30),
        @ItemID INT,
        @Needed INT,
        @Received INT,
        @Remaining INT,
        @Outstanding INT,
        @QuotationID INT,
        @WinnerID INT,
        @Price DECIMAL(10,2),
        @Total DECIMAL(12,2),
        @Budget DECIMAL(14,2),
        @Committed DECIMAL(14,2);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50502,
                'Purchasing is busy. Please try again.',
                1;

        DECLARE @DemandRepFID INT = @RepFID;

        IF @Action IN
        (
            'SaveQuotation',
            'Recommend',
            'CreatePO',
            'RevisePR'
        )
        BEGIN
            SELECT @DemandRepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS
            WHERE PRID = @PRID;
        END;

        IF @Action IN
        (
            'CreatePR',
            'SaveQuotation',
            'Recommend',
            'CreatePO',
            'RevisePR'
        )
        AND EXISTS
        (
            SELECT 1
            FROM dbo.REPLENISHMENT_REQUESTS rr
            INNER JOIN dbo.REQUISITIONS rq
                ON rq.RequisitionID = rr.OriginRequisitionID
            WHERE rr.RepFID = @DemandRepFID
              AND rq.Status = 'Cancelled'
        )
            THROW 50630,
                'The originating requisition was cancelled. Refresh Purchasing before continuing.',
                1;

        /* CREATE PR */

        IF @Action = 'CreatePR'
        BEGIN
            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            IF @Status IS NULL
               OR @Status <> 'Pending'
               OR @Needed <= @Received
                THROW 50503,
                    'Select a pending replenishment with an outstanding quantity.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS
                WHERE RepFID = @RepFID
            )
                THROW 50504,
                    'This replenishment already has a Purchase Request.',
                    1;

            INSERT INTO dbo.PURCHASE_REQUESTS
            (
                RepFID,
                CreatedByUserID,
                Status
            )
            VALUES
            (
                @RepFID,
                @ActorUserID,
                'Open'
            );

            SET @ResultID = SCOPE_IDENTITY();

            SET @Message =
                N'Purchase Request created. Replenishment remains pending for receiving.';
        END

        /* SAVE QUOTATION */

        ELSE IF @Action = 'SaveQuotation'
        BEGIN
            IF @PriceRaw IS NULL
               OR @PriceRaw < 0
               OR @PriceRaw > 99999999.99
               OR @PriceRaw <> ROUND(@PriceRaw, 2)
                THROW 50505,
                    'Enter a valid unit price with at most two decimal places.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID
                  AND Status IN ('Open', 'Pending Approval')
            )
                THROW 50506,
                    'This PR is not open for quotations.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507,
                    'Quotations cannot change while this PR has an active PO.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIERS
                WHERE SupplierID = @SupplierID
                  AND IsActive = 1
            )
                THROW 50508,
                    'Select an active supplier.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID
            )
            AND
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) >= 3
                THROW 50509,
                    'Only three supplier quotations are allowed per PR.',
                    1;

            SET @Price = CONVERT(DECIMAL(10,2), @PriceRaw);

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID
            )
            BEGIN
                UPDATE dbo.SUPPLIER_QUOTATIONS
                SET
                    QuotedPrice = @Price,
                    DateQuoted = SYSDATETIME()
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID;
            END
            ELSE
            BEGIN
                INSERT INTO dbo.SUPPLIER_QUOTATIONS
                (
                    PRID,
                    SupplierID,
                    QuotedPrice,
                    IsRecommended
                )
                VALUES
                (
                    @PRID,
                    @SupplierID,
                    @Price,
                    0
                );
            END;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) = 1
            BEGIN
                UPDATE q
                SET IsRecommended = 1
                FROM dbo.SUPPLIER_QUOTATIONS q
                INNER JOIN dbo.SUPPLIERS s
                    ON s.SupplierID = q.SupplierID
                   AND s.IsActive = 1
                WHERE q.PRID = @PRID;

                SET @Message =
                    N'Quotation saved. The only active supplier is recommended automatically.';
            END
            ELSE
            BEGIN
                SET @Message =
                    N'Quotation saved. Compare again before creating a PO.';
            END;
        END

        /* COMPARE AND RECOMMEND */

        ELSE IF @Action = 'Recommend'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID
                  AND Status = 'Open'
            )
                THROW 50506,
                    'Select an open PR for comparison.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509,
                    'Please select a supplier first and save one to three quotations.',
                    1;

            SELECT TOP (1)
                @QuotationID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND s.IsActive = 1
            ORDER BY
                q.QuotedPrice,
                q.QuotationID;

            IF @QuotationID IS NULL
                THROW 50508,
                    'No quotation from an active supplier is available.',
                    1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 1
            WHERE QuotationID = @QuotationID;

            SET @ResultID = @QuotationID;

            SET @Message =
                N'Lowest-priced active supplier recommended.';
        END

        /* CREATE PO */

        ELSE IF @Action = 'CreatePO'
        BEGIN
            SELECT @RepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
              AND Status = 'Open';

            IF @RepFID IS NULL
                THROW 50506,
                    'Select an open Purchase Request.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507,
                    'This PR already has an active PO.',
                    1;

            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            SET @Remaining = @Needed - @Received;

            IF @Status <> 'Pending'
               OR @Remaining IS NULL
               OR @Remaining <= 0
                THROW 50503,
                    'This replenishment no longer needs purchasing.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509,
                    'Please select a supplier first and save one to three quotations.',
                    1;

            SELECT TOP (1)
                @WinnerID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND s.IsActive = 1
            ORDER BY
                q.QuotedPrice,
                q.QuotationID;

            IF @WinnerID IS NULL
                THROW 50508,
                    'Please select an active supplier and save its quotation first.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) = 1
            BEGIN
                UPDATE dbo.SUPPLIER_QUOTATIONS
                SET IsRecommended = 1
                WHERE PRID = @PRID
                  AND QuotationID = @WinnerID;
            END;

            SELECT
                @QuotationID = q.QuotationID,
                @SupplierID = q.SupplierID,
                @Price = q.QuotedPrice
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND q.IsRecommended = 1
              AND s.IsActive = 1;

            IF @QuotationID IS NULL
               OR @QuotationID <> @WinnerID
                THROW 50511,
                    'Compare quotations again before creating the PO.',
                    1;

            IF @ExpectedDate IS NULL
               OR @ExpectedDate < CAST(SYSDATETIME() AS DATE)
                THROW 50510,
                    'Choose an expected delivery date of today or later.',
                    1;

            IF CONVERT(DECIMAL(20,2), @Remaining) * @Price
               > 9999999999.99
                THROW 50512,
                    'The PO amount exceeds the supported amount.',
                    1;

            SET @Total = @Remaining * @Price;
            SET @Year = YEAR(SYSDATETIME());

            SELECT @Budget = BudgetAmount
            FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
            WHERE BudgetYear = @Year
              AND IsActive = 1;

            SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE YEAR(DateIssued) = @Year
              AND Status IN
              (
                  'Approved',
                  'Sent to Supplier',
                  'Partially Delivered',
                  'Delivered'
              );

            IF @Budget IS NULL
               OR @Committed + @Total > @Budget
                THROW 50513,
                    'Configure a sufficient annual budget first.',
                    1;

            INSERT INTO dbo.PURCHASE_ORDERS
            (
                PRID,
                SupplierID,
                QuantityOrdered,
                UnitPrice,
                TotalAmount,
                Status
            )
            VALUES
            (
                @PRID,
                @SupplierID,
                @Remaining,
                @Price,
                @Total,
                'Pending Approval'
            );

            SET @POID = SCOPE_IDENTITY();
            SET @ResultID = @POID;

            INSERT INTO dbo.PO_PR_Mapping
            (
                POID,
                PRID
            )
            VALUES
            (
                @POID,
                @PRID
            );

            INSERT INTO dbo.PURCHASING_PO_TRACKING
            (
                POID,
                ExpectedDate,
                ReceivedBeforeOrder
            )
            VALUES
            (
                @POID,
                @ExpectedDate,
                @Received
            );

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Pending Approval'
            WHERE PRID = @PRID;

            SET @Message =
                N'PO created for the remaining quantity and awaiting approval.';
        END

        /* SET BUDGET */

        ELSE IF @Action = 'SetBudget'
        BEGIN
            IF @Year IS NULL
               OR @Year NOT BETWEEN 2000 AND 2100
               OR @AmountRaw IS NULL
               OR @AmountRaw < 0
               OR @AmountRaw > 999999999999.99
               OR @AmountRaw <> ROUND(@AmountRaw, 2)
                THROW 50514,
                    'Enter a valid budget year and amount.',
                    1;

            DECLARE @BudgetInput DECIMAL(14,2) =
                CONVERT(DECIMAL(14,2), @AmountRaw);

            EXEC dbo.usp_Purchasing_SetBudget
                @Year,
                @BudgetInput,
                @ActorUserID;

            SET @Message = N'Annual budget saved.';
        END

        /* APPROVE PO */

        ELSE IF @Action = 'ApprovePO'
        BEGIN
            EXEC dbo.usp_Purchasing_ApprovePO
                @POID,
                @ActorUserID;

            SET @Message = N'PO approved.';
        END

        /* REJECT PO (WITH MAKER-CHECKER GUARD) */

        ELSE IF @Action = 'RejectPO'
        BEGIN
            IF @Notes IS NULL
                THROW 50515,
                    'A rejection reason is required.',
                    1;

            DECLARE @RejectPOCreatorID INT = COALESCE(
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

            IF @RejectPOCreatorID = @ActorUserID
                THROW 50527,
                    'You cannot reject your own purchase order. Another authorized approver must review it.',
                    1;

            UPDATE dbo.PURCHASE_ORDERS
            SET Status = 'Rejected'
            WHERE POID = @POID
              AND Status = 'Pending Approval';

            IF @@ROWCOUNT <> 1
                THROW 50516,
                    'Only a pending PO can be rejected.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_PO_TRACKING
                WHERE POID = @POID
            )
            BEGIN
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);
            END;

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DecisionReason = @Notes
            WHERE POID = @POID;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Rejected'
            WHERE PRID =
            (
                SELECT PRID
                FROM dbo.PURCHASE_ORDERS
                WHERE POID = @POID
            )
            OR PRID IN
            (
                SELECT PRID
                FROM dbo.PO_PR_Mapping
                WHERE POID = @POID
            );

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
                pr.CreatedByUserID,
                'PO_REJECTED',
                'Purchase order rejected',
                @Notes,
                'PURCHASE_ORDER',
                @POID,
                0,
                SYSDATETIME()
            FROM dbo.PURCHASE_REQUESTS pr
            WHERE pr.PRID =
            (
                SELECT PRID
                FROM dbo.PURCHASE_ORDERS
                WHERE POID = @POID
            )
            OR pr.PRID IN
            (
                SELECT PRID
                FROM dbo.PO_PR_Mapping
                WHERE POID = @POID
            );

            SET @Message =
                N'PO rejected and Purchasing notified.';
        END

        /* REOPEN REJECTED PR */

        ELSE IF @Action = 'RevisePR'
        BEGIN
            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50517,
                    'A PR with an active PO cannot be reopened.',
                    1;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Open'
            WHERE PRID = @PRID
              AND Status = 'Rejected';

            IF @@ROWCOUNT <> 1
                THROW 50517,
                    'Only a rejected PR can be reopened.',
                    1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            SET @Message =
                N'PR reopened. Update quotations and compare again.';
        END

        /* MARK PO AS SENT TO SUPPLIER */

        ELSE IF @Action = 'DispatchPO'
        BEGIN
            UPDATE po
            SET Status = 'Sent to Supplier'
            FROM dbo.PURCHASE_ORDERS po
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = po.SupplierID
            WHERE po.POID = @POID
              AND po.Status = 'Approved'
              AND s.IsActive = 1;

            IF @@ROWCOUNT <> 1
                THROW 50518,
                    'Only an approved PO for an active supplier can be dispatched.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_PO_TRACKING
                WHERE POID = @POID
            )
            BEGIN
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);
            END;

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DispatchedAt = SYSDATETIME()
            WHERE POID = @POID;

            SET @Message =
                N'Supplier dispatch recorded.';
        END

        /* RECORD DELIVERY CHECK OR REPLACEMENT DELIVERY */

        ELSE IF @Action = 'RecordDR'
        BEGIN
            SELECT
                @ItemID = ItemID,
                @Outstanding = OutstandingQuantity,
                @Status = Status
            FROM dbo.vw_PurchasingWorkspacePO
            WHERE POID = @POID;

            IF @Status IS NULL
               OR @Status NOT IN
               (
                   'Sent to Supplier',
                   'Partially Delivered'
               )
                THROW 50519,
                    'Select a dispatched PO with outstanding quantities.',
                    1;

            IF @DRNumber IS NULL
                THROW 50520,
                    'Enter the supplier DR number.',
                    1;

            IF @Delivered IS NULL
               OR @Accepted IS NULL
               OR @Rejected IS NULL
               OR @Delivered <= 0
               OR @Accepted < 0
               OR @Rejected < 0
               OR CONVERT(BIGINT, @Accepted) + @Rejected <> @Delivered
               OR @Accepted > @Outstanding
                THROW 50521,
                    'Check delivered, accepted, rejected, and outstanding quantities.',
                    1;

            IF @Rejected > 0 AND @Notes IS NULL
                THROW 50522,
                    'Describe the damaged or rejected items.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_DR_TRACKING
                WHERE POID = @POID
                  AND SupplierDRNumber = @DRNumber
            )
                THROW 50523,
                    'That supplier DR is already recorded for this PO.',
                    1;

            INSERT INTO dbo.DELIVERY_RECEIPTS
            (
                POID,
                Status,
                Notes
            )
            VALUES
            (
                @POID,
                CASE
                    WHEN @Accepted = 0
                        THEN 'Rejected'
                    WHEN @Rejected > 0
                        THEN 'With Discrepancies'
                    ELSE 'Accepted'
                END,
                @Notes
            );

            SET @DRID = SCOPE_IDENTITY();
            SET @ResultID = @DRID;

            INSERT INTO dbo.DELIVERY_RECEIPT_DETAILS
            (
                DRID,
                ItemID,
                QuantityDelivered,
                QuantityAccepted,
                QuantityRejected,
                Remarks
            )
            VALUES
            (
                @DRID,
                @ItemID,
                @Delivered,
                @Accepted,
                @Rejected,
                LEFT(@Notes, 500)
            );

            INSERT INTO dbo.PURCHASING_DR_TRACKING
            (
                DRID,
                POID,
                SupplierDRNumber,
                RecordedByUserID
            )
            VALUES
            (
                @DRID,
                @POID,
                @DRNumber,
                @ActorUserID
            );

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
                'PURCHASE_DELIVERY',
                'Supplier delivery checked',
                CONCAT
                (
                    'PO #', @POID,
                    ', DR #', @DRID,
                    ': ', @Accepted,
                    ' accepted. Process this checked DR through Receiving.'
                ),
                'DELIVERY_RECEIPT',
                @DRID,
                0,
                SYSDATETIME()
            FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp
                ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p
                ON p.PermissionID = rp.PermissionID
            WHERE u.IsActive = 1
              AND p.PermissionCode = 'receiving.manage'
              AND @Accepted > 0;

            SET @Message =
                N'DR recorded. Accepted items await checked-DR receiving.';
        END

        /* RECORD THAT A REPLACEMENT WAS REQUESTED */

        ELSE IF @Action = 'ReplacementSent'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.DELIVERY_RECEIPT_DETAILS
                WHERE DRID = @DRID
                  AND QuantityRejected > 0
            )
                THROW 50524,
                    'This DR has no rejected items.',
                    1;

            UPDATE dbo.PURCHASING_DR_TRACKING
            SET ReplacementRequestedAt = SYSDATETIME()
            WHERE DRID = @DRID
              AND ReplacementRequestedAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50524,
                    'Replacement request already recorded or DR unavailable.',
                    1;

            SET @Message =
                N'Supplier replacement request recorded.';
        END

        /* RECORD THAT A FOLLOW-UP WAS SENT */

        ELSE IF @Action = 'FollowupSent'
        BEGIN
            UPDATE dbo.PURCHASING_FOLLOWUPS
            SET
                SentAt = SYSDATETIME(),
                SentByUserID = @ActorUserID
            WHERE FollowupID = @FollowupID
              AND SentAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50525,
                    'Follow-up already marked sent or unavailable.',
                    1;

            SET @Message =
                N'Follow-up marked sent.';
        END
        ELSE
        BEGIN
            ;THROW 50526,
                'Unknown purchasing action.',
                1;
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
            @ActorUserID,
            'PURCHASING_ACTION',
            CONCAT
            (
                @Action,
                '; PR=', @PRID,
                '; PO=', @POID,
                '; ', @Message
            )
        );

        COMMIT TRANSACTION;

        SELECT
            @ResultID AS ID,
            @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_Load
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;
    DECLARE @Admin BIT = 0;
    DECLARE @IsStaff BIT = 0;

    SELECT
        @IsStaff =
            CASE
                WHEN r.RoleName = N'Staff' THEN 1
                ELSE 0
            END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    IF @IsStaff = 0
       AND NOT EXISTS
       (
           SELECT 1
           FROM dbo.USERS u
           INNER JOIN dbo.ROLES r
               ON r.RoleID = u.RoleID
              AND r.IsActive = 1
           INNER JOIN dbo.ROLE_PERMISSIONS rp
               ON rp.RoleID = u.RoleID
           INNER JOIN dbo.PERMISSIONS p
               ON p.PermissionID = rp.PermissionID
           WHERE u.UserID = @ActorUserID
             AND u.IsActive = 1
             AND p.PermissionCode IN
             (
                 N'purchasing.view',
                 N'purchasing.manage'
             )
       )
        THROW 50501,
            'You do not have permission to view Purchasing.',
            1;

    SELECT
        @Manage = MAX(CASE WHEN p.PermissionCode = N'purchasing.manage' THEN 1 ELSE 0 END),
        @Approve = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END),
        @Admin = MAX(CASE WHEN p.PermissionCode = N'settings.manage' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SET @Manage = ISNULL(@Manage, 0);
    SET @Approve = ISNULL(@Approve, 0);
    SET @Admin = ISNULL(@Admin, 0);

    IF @Manage = 1
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @LockResult INT;

            EXEC @LockResult = sys.sp_getapplock
                @Resource = N'PurchasingWorkspace',
                @LockMode = 'Exclusive',
                @LockOwner = 'Transaction',
                @LockTimeout = 10000;

            IF @LockResult < 0
                THROW 50502,
                    'Purchasing is busy. Please refresh again.',
                    1;

            INSERT INTO dbo.PURCHASING_FOLLOWUPS
            (
                POID,
                ReminderDate,
                Message
            )
            SELECT
                po.POID,
                CAST(SYSDATETIME() AS DATE),
                CONCAT
                (
                    'Please follow up PO #', po.POID,
                    ' for ', po.ItemName,
                    '. Outstanding supplier quantity: ',
                    po.OutstandingQuantity,
                    '. Expected date: ',
                    CONVERT(VARCHAR(10), po.ExpectedDate, 23),
                    '.'
                )
            FROM dbo.vw_PurchasingWorkspacePO po
            WHERE po.Status IN
            (
                'Sent to Supplier',
                'Partially Delivered'
            )
              AND po.OutstandingQuantity > 0
              AND po.ExpectedDate <= CAST(SYSDATETIME() AS DATE)
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.PURCHASING_FOLLOWUPS f
                  WHERE f.POID = po.POID
                    AND f.ReminderDate =
                        CAST(SYSDATETIME() AS DATE)
              );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;
        END CATCH;
    END;

    /* Result 1: permissions */

    SELECT
        @Manage AS CanManage,
        @Approve AS CanApprove,
        @Admin AS CanSetBudget;

    /* Result 2: pending replenishments without a PR */

    SELECT
        rr.RepFID,
        i.ItemCode,
        i.ItemName,
        rr.QuantityNeeded - rr.QuantityReceived AS QuantityNeeded,
        rr.QuantityReceived,
        rr.OriginRequisitionID
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    WHERE rr.Status = 'Pending'
      AND rr.QuantityNeeded > rr.QuantityReceived
      AND
      (
          @IsStaff = 0
          OR EXISTS
          (
              SELECT 1
              FROM dbo.REQUISITIONS rq
              WHERE rq.RequisitionID = rr.OriginRequisitionID
                AND rq.RequestorUserID = @ActorUserID
          )
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITIONS rq
          WHERE rq.RequisitionID = rr.OriginRequisitionID
            AND rq.Status = 'Cancelled'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.PURCHASE_REQUESTS pr
          WHERE pr.RepFID = rr.RepFID
      )
    ORDER BY
        rr.DateGenerated,
        rr.RepFID;

    /* Result 3: purchase requests */

    SELECT
        pr.PRID,
        pr.RepFID,
        i.ItemCode,
        i.ItemName,
        CASE
            WHEN rr.QuantityNeeded > rr.QuantityReceived
                THEN rr.QuantityNeeded - rr.QuantityReceived
            ELSE 0
        END AS QuantityNeeded,
        rr.QuantityNeeded AS OriginalQuantityNeeded,
        rr.QuantityReceived,
        rr.OriginRequisitionID,
        pr.Status,
        CAST
        (
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.REQUISITIONS rq
                    WHERE rq.RequisitionID = rr.OriginRequisitionID
                      AND rq.Status = 'Cancelled'
                )
                    THEN 1
                ELSE 0
            END
            AS BIT
        ) AS OriginCancelled,
        pr.DateCreated
    FROM dbo.PURCHASE_REQUESTS pr
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    WHERE @IsStaff = 0
    ORDER BY pr.PRID DESC;

    /* Result 4: supplier quotations */

    SELECT
        q.QuotationID,
        q.PRID,
        q.SupplierID,
        s.SupplierName,
        s.IsActive,
        q.QuotedPrice,
        q.IsRecommended
    FROM dbo.SUPPLIER_QUOTATIONS q
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = q.SupplierID
    WHERE @IsStaff = 0
    ORDER BY
        q.PRID,
        q.QuotedPrice,
        q.QuotationID;

    /* Result 5: suppliers */

    SELECT
        SupplierID,
        SupplierName,
        Email,
        IsActive
    FROM dbo.SUPPLIERS
    WHERE @IsStaff = 0
    ORDER BY SupplierName;

    /* Result 6: purchase orders */

    SELECT *
    FROM dbo.vw_PurchasingWorkspacePO
    WHERE @IsStaff = 0
    ORDER BY POID DESC;

    /* Result 7: budgets */

    SELECT
        b.BudgetYear,
        b.BudgetAmount,
        ISNULL(c.Committed, 0) AS Committed,
        b.BudgetAmount - ISNULL(c.Committed, 0) AS Remaining
    FROM dbo.PURCHASE_BUDGETS b
    OUTER APPLY
    (
        SELECT SUM(po.TotalAmount) AS Committed
        FROM dbo.PURCHASE_ORDERS po
        WHERE YEAR(po.DateIssued) = b.BudgetYear
          AND po.Status IN
          (
              'Approved',
              'Sent to Supplier',
              'Partially Delivered',
              'Delivered'
          )
    ) c
    WHERE b.IsActive = 1
      AND @IsStaff = 0
    ORDER BY b.BudgetYear DESC;

    /* Result 8: delivery checks and receiving status */

    SELECT
        dr.DRID,
        dr.POID,
        tr.SupplierDRNumber,
        dr.DeliveryDate,
        dr.Status,
        dr.Notes,
        d.QuantityDelivered,
        d.QuantityAccepted,
        d.QuantityRejected,
        rm.RMID,
        rm.InventoryUpdated,
        tr.ReplacementRequestedAt
    FROM dbo.DELIVERY_RECEIPTS dr
    LEFT JOIN dbo.PURCHASING_DR_TRACKING tr
        ON tr.DRID = dr.DRID
    LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS d
        ON d.DRID = dr.DRID
    LEFT JOIN dbo.RECEIVING_MEMOS rm
        ON rm.DRID = dr.DRID
    WHERE @IsStaff = 0
    ORDER BY dr.DRID DESC;

    /* Result 9: follow-up drafts */

    SELECT
        f.*,
        s.SupplierName,
        s.Email
    FROM dbo.PURCHASING_FOLLOWUPS f
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.POID = f.POID
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = po.SupplierID
    WHERE @IsStaff = 0
    ORDER BY f.FollowupID DESC;
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
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_BeginEmailLog
    @ActorUserID INT,
    @POID INT,
    @EmailType VARCHAR(30) = 'PURCHASE_ORDER',
    @FollowupID INT = NULL,
    @Subject NVARCHAR(300) = NULL
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
          AND p.PermissionCode IN (N'purchasing.manage', N'requisitions.approve')
    )
        THROW 50550,
            'You do not have permission to send supplier emails.',
            1;

    DECLARE
        @POStatus VARCHAR(30),
        @SupplierName NVARCHAR(200),
        @RecipientEmail NVARCHAR(255);

    SELECT
        @POStatus = po.Status,
        @SupplierName = s.SupplierName,
        @RecipientEmail = LTRIM(RTRIM(ISNULL(s.Email, N'')))
    FROM dbo.PURCHASE_ORDERS po
    INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
    WHERE po.POID = @POID;

    IF @POStatus IS NULL
        THROW 50551, 'The purchase order could not be found.', 1;

    IF @EmailType = 'PURCHASE_ORDER'
       AND @POStatus IN ('Pending Approval', 'Rejected', 'Cancelled')
        THROW 50552,
            'Only approved purchase orders can be emailed to the supplier.',
            1;

    IF @RecipientEmail = N''
        THROW 50553,
            'This supplier has no email address on file. Update the supplier record under Suppliers first.',
            1;

    IF @RecipientEmail NOT LIKE N'%_@_%._%'
       OR CHARINDEX(N' ', @RecipientEmail) > 0
       OR CHARINDEX(N'@', @RecipientEmail, CHARINDEX(N'@', @RecipientEmail) + 1) > 0
        THROW 50554,
            'The supplier email address on file is not valid. Please update it under Suppliers first.',
            1;

    DECLARE @FinalSubject NVARCHAR(300) =
        ISNULL(NULLIF(LTRIM(RTRIM(@Subject)), N''),
               CONCAT(N'Purchase Order PO-', RIGHT('0000' + CAST(@POID AS VARCHAR(10)), 4)));

    INSERT INTO dbo.EMAIL_LOGS
    (
        POID,
        EmailType,
        FollowupID,
        RecipientEmail,
        Subject,
        EmailStatus,
        TriggeredByUserID,
        CreatedAt
    )
    VALUES
    (
        @POID,
        LEFT(ISNULL(NULLIF(@EmailType, ''), 'PURCHASE_ORDER'), 30),
        @FollowupID,
        @RecipientEmail,
        LEFT(@FinalSubject, 300),
        'Pending',
        @ActorUserID,
        SYSDATETIME()
    );

    DECLARE @EmailLogID BIGINT = SCOPE_IDENTITY();

    SELECT
        @EmailLogID AS EmailLogID,
        @POID AS POID,
        @SupplierName AS SupplierName,
        @RecipientEmail AS RecipientEmail,
        @POStatus AS POStatus,
        'Pending' AS EmailStatus;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Email_GetRuntimeConfig
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN (N'purchasing.manage', N'requisitions.approve', N'settings.manage')
    )
        THROW 50378, 'You do not have permission to access salon email dispatch configuration.', 1;

    SELECT TOP (1)
        es.SenderEmail,
        es.SenderName,
        es.EncryptedAppPassword,
        es.SmtpHost,
        es.SmtpPort,
        es.UseStartTls
    FROM dbo.EMAIL_SETTINGS es
    WHERE es.SettingID = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_AssignRole
    @ActorUserID INT,
    @TargetUserID INT,
    @NewRoleID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ActorActive BIT = 0;
    DECLARE @CanAssign BIT = 0;
    DECLARE @NewRole NVARCHAR(50);
    DECLARE @TargetRole NVARCHAR(50);

    SELECT
        @ActorActive = 1,
        @CanAssign = MAX(CASE WHEN p.PermissionCode = N'users.assign_role' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SELECT @NewRole = RoleName
    FROM dbo.ROLES
    WHERE RoleID = @NewRoleID
      AND IsActive = 1;

    SELECT @TargetRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @TargetUserID;

    IF ISNULL(@ActorActive, 0) = 0
        THROW 50001, 'Invalid or inactive account.', 1;

    IF ISNULL(@CanAssign, 0) = 0
        THROW 50002, 'You do not have permission to assign user roles.', 1;

    IF @NewRole IS NULL
        THROW 50003, 'Invalid role.', 1;

    IF @NewRole = N'Admin'
        THROW 50004, 'Admin role cannot be assigned through this procedure.', 1;

    IF @TargetRole IS NULL
        THROW 50005, 'Target user was not found.', 1;

    IF @TargetRole = N'Admin'
        THROW 50006,
            'Admin accounts cannot be changed through this procedure.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.USERS
    SET RoleID = @NewRoleID
    WHERE UserID = @TargetUserID;

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50007, 'Target user was not found.', 1;
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
        @TargetUserID,
        'ROLE_CHANGED',
        CONCAT('Role changed to ', @NewRole)
    );

    COMMIT TRANSACTION;
END;
GO
