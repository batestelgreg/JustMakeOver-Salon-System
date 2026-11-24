/*
    V026_PurchasingWorkflow.sql

    Apply after V025.

    Includes:
    - Automatic recommendation for one saved active quotation.
    - Supplier validation before expected delivery date.
    - Cancellation handling for uncommitted replenishments.
    - PO review and approval notifications.
    - Updated Purchasing workspace results.

    Preserves:
    - V019 generated delivery references.
    - V024 stock allocation.
    - V025 checked-delivery receiving.

    Stock Shortage notification routing remains unchanged.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. RECONCILE CANCELLED REQUISITION DEMAND
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_ReconcileCancelledDemand
    @RequisitionID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Cancelled'
    )
        RETURN;

    DECLARE
        @RepFID INT,
        @ItemID INT,
        @Available INT,
        @Reorder INT,
        @Unallocated INT,
        @OtherIncoming INT,
        @Needed INT,
        @NextOrigin INT;

    DECLARE candidates CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            rr.RepFID,
            rr.ItemID
        FROM dbo.REPLENISHMENT_REQUESTS rr WITH (UPDLOCK, HOLDLOCK)
        WHERE rr.OriginRequisitionID = @RequisitionID
          AND rr.Status = 'Pending'
          AND rr.QuantityReceived = 0
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PURCHASE_REQUESTS pr
              WHERE pr.RepFID = rr.RepFID
          )
        ORDER BY rr.RepFID;

    OPEN candidates;

    FETCH NEXT FROM candidates
    INTO @RepFID, @ItemID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @Available = NULL,
            @Reorder = NULL,
            @NextOrigin = NULL;

        SELECT
            @Available =
                CASE
                    WHEN inv.QuantityOnHand > inv.QuantityReserved
                        THEN inv.QuantityOnHand - inv.QuantityReserved
                    ELSE 0
                END,
            @Reorder = i.ReorderPoint
        FROM dbo.INVENTORY inv WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.ITEMS i
            ON i.ItemID = inv.ItemID
        WHERE inv.ItemID = @ItemID;

        IF @Available IS NULL
            THROW 50631,
                'Cannot reconcile cancelled demand: the item stock record is missing.',
                1;

        SELECT
            @Unallocated = ISNULL
            (
                SUM
                (
                    CASE
                        WHEN ISNULL(rd.QuantityApproved, rd.QuantityRequested)
                             > ISNULL(res.Qty, 0)
                        THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested)
                             - ISNULL(res.Qty, 0)
                        ELSE 0
                    END
                ),
                0
            )
        FROM dbo.REQUISITION_DETAILS rd
        INNER JOIN dbo.REQUISITIONS rq
            ON rq.RequisitionID = rd.RequisitionID
        OUTER APPLY
        (
            SELECT SUM(ir.QuantityReserved) AS Qty
            FROM dbo.INVENTORY_RESERVATIONS ir
            WHERE ir.RequisitionDetailID = rd.RequisitionDetailID
              AND ir.Status = 'Active'
        ) res
        WHERE rd.ItemID = @ItemID
          AND rq.Status = 'Approved'
          AND rd.Status IN ('Pending', 'Partially Fulfilled');

        SELECT
            @OtherIncoming = ISNULL
            (
                SUM(rr.QuantityNeeded - rr.QuantityReceived),
                0
            )
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.ItemID = @ItemID
          AND rr.Status = 'Pending'
          AND rr.RepFID <> @RepFID
          AND rr.QuantityNeeded > rr.QuantityReceived
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.REQUISITIONS rq
              WHERE rq.RequisitionID = rr.OriginRequisitionID
                AND rq.Status = 'Cancelled'
          );

        /*
            Preserve independently valid demand.

            A cancelled requisition does not necessarily mean that
            the item no longer needs replenishment.
        */
        SET @Needed =
            CASE
                WHEN @Unallocated > ISNULL(@Reorder, 0)
                    THEN @Unallocated
                ELSE ISNULL(@Reorder, 0)
            END
            - @Available
            - @OtherIncoming;

        IF @Needed > 0
        BEGIN
            SELECT TOP (1)
                @NextOrigin = rd.RequisitionID
            FROM dbo.REQUISITION_DETAILS rd
            INNER JOIN dbo.REQUISITIONS rq
                ON rq.RequisitionID = rd.RequisitionID
            WHERE rd.ItemID = @ItemID
              AND rq.Status = 'Approved'
              AND rd.Status IN ('Pending', 'Partially Fulfilled')
            ORDER BY
                rq.RequestDate,
                rd.RequisitionDetailID;

            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET
                QuantityNeeded = @Needed,
                OriginRequisitionID = @NextOrigin
            WHERE RepFID = @RepFID;
        END
        ELSE
        BEGIN
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET Status = 'Cancelled'
            WHERE RepFID = @RepFID;
        END;

        UPDATE dbo.NOTIFICATIONS
        SET
            IsRead = 1,
            ReadAt = SYSDATETIME()
        WHERE RelatedEntityType = 'REPLENISHMENT_REQUEST'
          AND RelatedEntityID = @RepFID
          AND NotificationType = 'STOCK_SHORTAGE'
          AND IsRead = 0;

        FETCH NEXT FROM candidates
        INTO @RepFID, @ItemID;
    END;

    CLOSE candidates;
    DEALLOCATE candidates;
END;
GO

/* ============================================================
   2. APPLY RECONCILIATION WHEN A REQUISITION IS CANCELLED
   ============================================================ */

CREATE OR ALTER TRIGGER dbo.trg_Purchasing_RequisitionCancelled
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ID INT;

    DECLARE changed CURSOR LOCAL FAST_FORWARD FOR
        SELECT i.RequisitionID
        FROM inserted i
        INNER JOIN deleted d
            ON d.RequisitionID = i.RequisitionID
        WHERE i.Status = 'Cancelled'
          AND d.Status <> 'Cancelled';

    OPEN changed;

    FETCH NEXT FROM changed INTO @ID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Purchasing_ReconcileCancelledDemand
            @RequisitionID = @ID;

        FETCH NEXT FROM changed INTO @ID;
    END;

    CLOSE changed;
    DEALLOCATE changed;
END;
GO

/* ============================================================
   3. RECONCILE EXISTING CANCELLED, UNCOMMITTED REPLENISHMENTS
   ============================================================ */

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @CancelledID INT;

    DECLARE backfill CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT rr.OriginRequisitionID
        FROM dbo.REPLENISHMENT_REQUESTS rr
        INNER JOIN dbo.REQUISITIONS rq
            ON rq.RequisitionID = rr.OriginRequisitionID
        WHERE rq.Status = 'Cancelled'
          AND rr.Status = 'Pending'
          AND rr.QuantityReceived = 0
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PURCHASE_REQUESTS pr
              WHERE pr.RepFID = rr.RepFID
          );

    OPEN backfill;

    FETCH NEXT FROM backfill INTO @CancelledID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Purchasing_ReconcileCancelledDemand
            @RequisitionID = @CancelledID;

        FETCH NEXT FROM backfill INTO @CancelledID;
    END;

    CLOSE backfill;
    DEALLOCATE backfill;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

/* ============================================================
   4. PURCHASING ACTIONS
   ============================================================ */

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

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'purchasing.manage'
    )
        SET @Manage = 1;

    SELECT
        @Approve =
            CASE
                WHEN r.RoleName IN (N'Admin', N'Manager')
                    THEN 1
                ELSE 0
            END,
        @Admin =
            CASE
                WHEN r.RoleName = N'Admin'
                    THEN 1
                ELSE 0
            END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    IF @Action IN ('ApprovePO', 'RejectPO')
    BEGIN
        IF @Approve = 0
            THROW 50501,
                'Only an Admin or Manager may decide a PO.',
                1;
    END
    ELSE IF @Action = 'SetBudget'
    BEGIN
        IF @Admin = 0
            THROW 50501,
                'Only an Admin may configure the budget.',
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

        /* REJECT PO */

        ELSE IF @Action = 'RejectPO'
        BEGIN
            IF @Notes IS NULL
                THROW 50515,
                    'A rejection reason is required.',
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

/* ============================================================
   5. PURCHASING WORKSPACE LOAD
   Keep the existing nine-result-set order for C#.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_Load
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;
    DECLARE @Admin BIT = 0;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN
          (
              'purchasing.view',
              'purchasing.manage'
          )
    )
        THROW 50501,
            'You do not have permission to view Purchasing.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'purchasing.manage'
    )
        SET @Manage = 1;

    SELECT
        @Approve =
            CASE
                WHEN r.RoleName IN ('Admin', 'Manager')
                    THEN 1
                ELSE 0
            END,
        @Admin =
            CASE
                WHEN r.RoleName = 'Admin'
                    THEN 1
                ELSE 0
            END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

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
    ORDER BY SupplierName;

    /* Result 6: purchase orders */

    SELECT *
    FROM dbo.vw_PurchasingWorkspacePO
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
    ORDER BY f.FollowupID DESC;
END;
GO

/* ============================================================
   6. PR AND QUOTATION REMOVAL
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithRemoval
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Action IS NULL
       OR @Action NOT IN ('RemovePR', 'RemoveQuotation')
    BEGIN
        EXEC dbo.usp_PurchasingWorkspace_Action
            @ActorUserID = @ActorUserID,
            @Action = @Action,
            @Payload = @Payload;

        RETURN;
    END;

    IF @Payload IS NULL OR ISJSON(@Payload) <> 1
        THROW 50600,
            'Invalid purchasing request.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = r.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND r.IsActive = 1
          AND p.PermissionCode = N'purchasing.manage'
    )
        THROW 50601,
            'Purchasing management permission is required.',
            1;

    DECLARE @PRID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID'));

    DECLARE @QuotationID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.quotationID'));

    DECLARE @LockResult INT;
    DECLARE @ResultID INT;
    DECLARE @Message NVARCHAR(300);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50602,
                'Purchasing is busy. Please try again.',
                1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            SET @PRID = NULL;

            SELECT @PRID = PRID
            FROM dbo.SUPPLIER_QUOTATIONS WITH (UPDLOCK, HOLDLOCK)
            WHERE QuotationID = @QuotationID;

            IF @PRID IS NULL
                THROW 50603,
                    'This quotation no longer exists.',
                    1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
              AND Status = 'Open'
        )
            THROW 50604,
                'Only an open Purchase Request can be changed.',
                1;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
        )
        OR EXISTS
        (
            SELECT 1
            FROM dbo.PO_PR_Mapping WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
        )
            THROW 50605,
                'Records with Purchase Order history cannot be removed.',
                1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE QuotationID = @QuotationID
              AND PRID = @PRID;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            SET @ResultID = @QuotationID;

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
                INNER JOIN dbo.SUPPLIERS supplier
                    ON supplier.SupplierID = q.SupplierID
                   AND supplier.IsActive = 1
                WHERE q.PRID = @PRID;

                SET @Message =
                    N'Quotation removed. The remaining active supplier is recommended automatically.';
            END
            ELSE
            BEGIN
                SET @Message =
                    N'Quotation removed. Compare the remaining quotations again.';
            END;
        END
        ELSE
        BEGIN
            DECLARE @RemovedRepFID INT =
            (
                SELECT RepFID
                FROM dbo.PURCHASE_REQUESTS
                WHERE PRID = @PRID
            );

            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE PRID = @PRID;

            DELETE FROM dbo.PURCHASE_REQUESTS
            WHERE PRID = @PRID;

            SET @ResultID = @PRID;

            SET @Message =
                N'Purchase Request and its quotations removed.';
        END;

        IF @Action = 'RemovePR'
        BEGIN
            DECLARE @CancelledOrigin INT =
            (
                SELECT rr.OriginRequisitionID
                FROM dbo.REPLENISHMENT_REQUESTS rr
                INNER JOIN dbo.REQUISITIONS rq
                    ON rq.RequisitionID = rr.OriginRequisitionID
                WHERE rr.RepFID = @RemovedRepFID
                  AND rq.Status = 'Cancelled'
            );

            IF @CancelledOrigin IS NOT NULL
            BEGIN
                EXEC dbo.usp_Purchasing_ReconcileCancelledDemand
                    @RequisitionID = @CancelledOrigin;
            END;
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
                '; Quotation=', @QuotationID,
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

/* ============================================================
   7. MANAGER REVIEW AND PURCHASING APPROVAL NOTIFICATIONS
   ============================================================ */

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
      AND r.RoleName IN ('Admin', 'Manager')
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