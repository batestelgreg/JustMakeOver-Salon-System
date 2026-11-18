/*
   

    Purchasing:
      Replenishment -> PR -> quotations -> recommendation -> PO
      -> budget check -> approval -> dispatch -> supplier DR check.

    Receiving:
      Accepted DR -> usp_Purchasing_ReceiveCheckedDR
      -> V011 usp_Inventory_ReceiveStock
      -> RM recorded as already applied to inventory.

    Important:
      - PR/PO creation never marks the replenishment Processed.
      - QuantityReceived is changed only by the receiving engine.
      - The same supplier delivery must not be received through
        both the direct RepF form and the checked-DR procedure.
      - Supplier email sending is handled outside this SQL script.
*/

USE JustMakeOverSalonDB;
GO

/* 
   1. REQUIREMENTS
 */

IF COL_LENGTH(
    'dbo.REPLENISHMENT_REQUESTS', 'QuantityReceived'
) IS NULL
    THROW 50500, 'Execute V011_FlowFixes.sql before V012.', 1;
GO

IF OBJECT_ID('dbo.DELIVERY_RECEIPT_DETAILS', 'U') IS NULL
    THROW 50500, 'The base delivery receipt tables are missing.', 1;
GO

IF OBJECT_ID('dbo.usp_Inventory_ReceiveStock', 'P') IS NULL
    THROW 50500, 'The receiving procedure is missing.', 1;
GO

/* 
   2. PURCHASING TRACKING TABLES
*/

IF OBJECT_ID('dbo.PURCHASING_PO_TRACKING', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PURCHASING_PO_TRACKING
    (
        POID INT NOT NULL
            CONSTRAINT PK_PURCHASING_PO_TRACKING PRIMARY KEY
            REFERENCES dbo.PURCHASE_ORDERS(POID),

        ExpectedDate DATE NULL,
        DispatchedAt DATETIME2 NULL,
        DecisionReason NVARCHAR(1000) NULL,

        -- Snapshot of the RepF's received quantity when ordering.
        -- A new PO orders only what remains at that time.
        ReceivedBeforeOrder INT NOT NULL
            CONSTRAINT DF_PURCHASING_PO_ReceivedBefore DEFAULT (0)
    );
END;
GO

-- Supports upgrading an earlier, already-created tracking table.
IF COL_LENGTH(
    'dbo.PURCHASING_PO_TRACKING', 'ReceivedBeforeOrder'
) IS NULL
BEGIN
    ALTER TABLE dbo.PURCHASING_PO_TRACKING
        ADD ReceivedBeforeOrder INT NOT NULL
            CONSTRAINT DF_PURCHASING_PO_ReceivedBeforeUpgrade DEFAULT (0);
END;
GO

IF OBJECT_ID('dbo.PURCHASING_FOLLOWUPS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PURCHASING_FOLLOWUPS
    (
        FollowupID INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_PURCHASING_FOLLOWUPS PRIMARY KEY,

        POID INT NOT NULL
            REFERENCES dbo.PURCHASE_ORDERS(POID),

        ReminderDate DATE NOT NULL,
        Message NVARCHAR(2000) NOT NULL,
        SentAt DATETIME2 NULL,
        SentByUserID INT NULL REFERENCES dbo.USERS(UserID),

        CONSTRAINT UQ_PURCHASING_FOLLOWUP_DAY
            UNIQUE (POID, ReminderDate)
    );
END;
GO

IF OBJECT_ID('dbo.PURCHASING_DR_TRACKING', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PURCHASING_DR_TRACKING
    (
        DRID INT NOT NULL
            CONSTRAINT PK_PURCHASING_DR_TRACKING PRIMARY KEY
            REFERENCES dbo.DELIVERY_RECEIPTS(DRID),

        POID INT NOT NULL REFERENCES dbo.PURCHASE_ORDERS(POID),
        SupplierDRNumber NVARCHAR(100) NOT NULL,
        RecordedByUserID INT NOT NULL REFERENCES dbo.USERS(UserID),
        ReplacementRequestedAt DATETIME2 NULL,

        CONSTRAINT UQ_PURCHASING_SUPPLIER_DR
            UNIQUE (POID, SupplierDRNumber)
    );
END;
GO

/* 
   3. CONSERVATIVE REPAIR OF LEGACY PR STATUS

   The old CreatePR procedure marked an unreceived RepF Processed.

   Repair only requests with:
     - an existing PR;
     - zero recorded QuantityReceived;
     - no matching stock-in evidence;
     - no applied Receiving Memo for the PR.

   Records with receiving evidence are left for reconciliation.
*/

UPDATE f
SET Status = 'Pending'
FROM dbo.REPLENISHMENT_REQUESTS f
WHERE f.Status = 'Processed'
  AND f.QuantityReceived = 0
  AND f.QuantityNeeded > 0
  AND EXISTS
  (
      SELECT 1
      FROM dbo.PURCHASE_REQUESTS pr
      WHERE pr.RepFID = f.RepFID
  )
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.INVENTORY_LOGS l
      WHERE l.ReferenceType = 'REPLENISHMENT'
        AND l.ReferenceID = f.RepFID
        AND l.TransactionType = 'Stock In'
  )
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.PURCHASE_REQUESTS pr
      INNER JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
      INNER JOIN dbo.DELIVERY_RECEIPTS dr ON dr.POID = po.POID
      INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
      WHERE pr.RepFID = f.RepFID
        AND rm.InventoryUpdated = 1
  )
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.PURCHASE_REQUESTS pr
      INNER JOIN dbo.PO_PR_Mapping map ON map.PRID = pr.PRID
      INNER JOIN dbo.DELIVERY_RECEIPTS dr ON dr.POID = map.POID
      INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
      WHERE pr.RepFID = f.RepFID
        AND rm.InventoryUpdated = 1
  );
GO

/*
   4. PO SUMMARY
*/

CREATE OR ALTER VIEW dbo.vw_PurchasingWorkspacePO
AS
SELECT
    po.POID,
    po.PRID,
    po.SupplierID,
    s.SupplierName,
    s.Email AS SupplierEmail,
    rr.RepFID,
    rr.OriginRequisitionID,
    rr.ItemID,
    i.ItemCode,
    i.ItemName,
    po.QuantityOrdered,
    po.UnitPrice,
    po.TotalAmount,
    po.Status,
    po.DateIssued,
    YEAR(po.DateIssued) AS BudgetYear,
    t.ExpectedDate,
    t.DispatchedAt,
    t.DecisionReason,
    ISNULL(t.ReceivedBeforeOrder, 0) AS ReceivedBeforeOrder,
    rr.QuantityReceived AS RepFQuantityReceived,
    ISNULL(a.AcceptedQuantity, 0) AS AcceptedQuantity,
    po.QuantityOrdered - ISNULL(a.AcceptedQuantity, 0)
        AS OutstandingQuantity,
    ISNULL(m.StockedQuantity, 0) AS StockedQuantity
FROM dbo.PURCHASE_ORDERS po
INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
LEFT JOIN dbo.PURCHASING_PO_TRACKING t ON t.POID = po.POID
OUTER APPLY
(
    SELECT SUM(drd.QuantityAccepted) AS AcceptedQuantity
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd ON drd.DRID = dr.DRID
    WHERE dr.POID = po.POID
) a
OUTER APPLY
(
    SELECT SUM(rmd.QuantityReceived) AS StockedQuantity
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
    INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
    WHERE dr.POID = po.POID
      AND rm.InventoryUpdated = 1
) m;
GO

/* 
   5. PURCHASING ACTIONS

   Compatible with the C# PurchasingWorkspaceAction operation.
 */

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
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'purchasing.manage'
    )
        SET @Manage = 1;

    SELECT
        @Approve = CASE
            WHEN r.RoleName IN (N'Admin', N'Manager') THEN 1 ELSE 0 END,
        @Admin = CASE WHEN r.RoleName = N'Admin' THEN 1 ELSE 0 END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    IF @Action IN ('ApprovePO', 'RejectPO')
    BEGIN
        IF @Approve = 0
            THROW 50501, 'Only an Admin or Manager may decide a PO.', 1;
    END
    ELSE IF @Action = 'SetBudget'
    BEGIN
        IF @Admin = 0
            THROW 50501, 'Only an Admin may configure the budget.', 1;
    END
    ELSE IF @Manage = 0
        THROW 50501, 'Purchasing management permission is required.', 1;

    DECLARE
        @PRID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID')),
        @RepFID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.repFID')),
        @POID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.poID')),
        @SupplierID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.supplierID')),
        @FollowupID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.followupID')),
        @DRID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.drID')),
        @Year INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.year')),
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
        THROW 50500, 'Notes must be 1000 characters or fewer.', 1;

    IF LEN(@DRInput) > 100
        THROW 50500, 'The supplier DR number must be 100 characters or fewer.', 1;

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
            THROW 50502, 'Purchasing is busy. Please try again.', 1;

        /* 
           CREATE PR
           Keep the RepF Pending for V011 Receiving.
  */

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
                THROW 50503, 'Select a pending replenishment with an outstanding quantity.', 1;

            IF EXISTS
            (
                SELECT 1 FROM dbo.PURCHASE_REQUESTS
                WHERE RepFID = @RepFID
            )
                THROW 50504, 'This replenishment already has a Purchase Request.', 1;

            INSERT INTO dbo.PURCHASE_REQUESTS
                (RepFID, CreatedByUserID, Status)
            VALUES
                (@RepFID, @ActorUserID, 'Open');

            SET @ResultID = SCOPE_IDENTITY();

            -- Intentionally no RepF status update here.
            SET @Message = N'Purchase Request created. Replenishment remains pending for receiving.';
        END

        /* 
           SAVE QUOTATION
   */

        ELSE IF @Action = 'SaveQuotation'
        BEGIN
            IF @PriceRaw IS NULL
               OR @PriceRaw < 0
               OR @PriceRaw > 99999999.99
               OR @PriceRaw <> ROUND(@PriceRaw, 2)
                THROW 50505, 'Enter a valid unit price with at most two decimal places.', 1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID
                  AND Status IN ('Open', 'Pending Approval')
            )
                THROW 50506, 'This PR is not open for quotations.', 1;

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
                          SELECT 1 FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507, 'Quotations cannot change while this PR has an active PO.', 1;

            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.SUPPLIERS
                WHERE SupplierID = @SupplierID AND IsActive = 1
            )
                THROW 50508, 'Select an active supplier.', 1;

            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID AND SupplierID = @SupplierID
            )
            AND
            (
                SELECT COUNT(*) FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) >= 3
                THROW 50509, 'Only three supplier quotations are allowed per PR.', 1;

            SET @Price = CONVERT(DECIMAL(10,2), @PriceRaw);

            -- Editing prices invalidates the previous comparison.
            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            IF EXISTS
            (
                SELECT 1 FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID AND SupplierID = @SupplierID
            )
            BEGIN
                UPDATE dbo.SUPPLIER_QUOTATIONS
                SET QuotedPrice = @Price,
                    DateQuoted = SYSDATETIME()
                WHERE PRID = @PRID AND SupplierID = @SupplierID;
            END
            ELSE
            BEGIN
                INSERT INTO dbo.SUPPLIER_QUOTATIONS
                    (PRID, SupplierID, QuotedPrice, IsRecommended)
                VALUES
                    (@PRID, @SupplierID, @Price, 0);
            END;

            SET @Message = N'Quotation saved. Compare again before creating a PO.';
        END

        /* 
           COMPARE AND RECOMMEND
    */

        ELSE IF @Action = 'Recommend'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID AND Status = 'Open'
            )
                THROW 50506, 'Select an open PR for comparison.', 1;

            IF
            (
                SELECT COUNT(*) FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509, 'Record one to three quotations first.', 1;

            SELECT TOP (1)
                @QuotationID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID AND s.IsActive = 1
            ORDER BY q.QuotedPrice, q.QuotationID;

            IF @QuotationID IS NULL
                THROW 50508, 'No quotation from an active supplier is available.', 1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0 WHERE PRID = @PRID;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 1 WHERE QuotationID = @QuotationID;

            SET @ResultID = @QuotationID;
            SET @Message = N'Lowest-priced active supplier recommended.';
        END

        /* 
           CREATE PO
           Order remaining quantity, not original QuantityNeeded.
           Do not call the legacy CreatePO procedure because it
           requires a Processed RepF.
           */

        ELSE IF @Action = 'CreatePO'
        BEGIN
            IF @ExpectedDate IS NULL
               OR @ExpectedDate < CAST(SYSDATETIME() AS DATE)
                THROW 50510, 'Choose an expected delivery date of today or later.', 1;

            SELECT @RepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID AND Status = 'Open';

            IF @RepFID IS NULL
                THROW 50506, 'Select an open Purchase Request.', 1;

            IF EXISTS
            (
                SELECT 1 FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1 FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507, 'This PR already has an active PO.', 1;

            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            SET @Remaining = @Needed - @Received;

            IF @Status <> 'Pending' OR @Remaining IS NULL OR @Remaining <= 0
                THROW 50503, 'This replenishment no longer needs purchasing.', 1;

            IF
            (
                SELECT COUNT(*) FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509, 'Record one to three quotations first.', 1;

            SELECT TOP (1)
                @WinnerID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID AND s.IsActive = 1
            ORDER BY q.QuotedPrice, q.QuotationID;

            SELECT
                @QuotationID = q.QuotationID,
                @SupplierID = q.SupplierID,
                @Price = q.QuotedPrice
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND q.IsRecommended = 1
              AND s.IsActive = 1;

            IF @QuotationID IS NULL OR @QuotationID <> @WinnerID
                THROW 50511, 'Compare quotations again before creating the PO.', 1;

            IF CONVERT(DECIMAL(20,2), @Remaining) * @Price > 9999999999.99
                THROW 50512, 'The PO amount exceeds the supported amount.', 1;

            SET @Total = @Remaining * @Price;
            SET @Year = YEAR(SYSDATETIME());

            SELECT @Budget = BudgetAmount
            FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
            WHERE BudgetYear = @Year AND IsActive = 1;

            SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE YEAR(DateIssued) = @Year
              AND Status IN
              (
                  'Approved', 'Sent to Supplier',
                  'Partially Delivered', 'Delivered'
              );

            IF @Budget IS NULL OR @Committed + @Total > @Budget
                THROW 50513, 'Configure a sufficient annual budget first.', 1;

            INSERT INTO dbo.PURCHASE_ORDERS
            (
                PRID, SupplierID, QuantityOrdered,
                UnitPrice, TotalAmount, Status
            )
            VALUES
            (
                @PRID, @SupplierID, @Remaining,
                @Price, @Total, 'Pending Approval'
            );

            SET @POID = SCOPE_IDENTITY();
            SET @ResultID = @POID;

            INSERT INTO dbo.PO_PR_Mapping (POID, PRID)
            VALUES (@POID, @PRID);

            INSERT INTO dbo.PURCHASING_PO_TRACKING
                (POID, ExpectedDate, ReceivedBeforeOrder)
            VALUES
                (@POID, @ExpectedDate, @Received);

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Pending Approval'
            WHERE PRID = @PRID;

            SET @Message = N'PO created for the remaining quantity and awaiting approval.';
        END

        /*
           BUDGET
           */

        ELSE IF @Action = 'SetBudget'
        BEGIN
            IF @Year IS NULL OR @Year NOT BETWEEN 2000 AND 2100
               OR @AmountRaw IS NULL OR @AmountRaw < 0
               OR @AmountRaw > 999999999999.99
               OR @AmountRaw <> ROUND(@AmountRaw, 2)
                THROW 50514, 'Enter a valid budget year and amount.', 1;

            DECLARE @BudgetInput DECIMAL(14,2) =
                CONVERT(DECIMAL(14,2), @AmountRaw);

            EXEC dbo.usp_Purchasing_SetBudget
                @Year, @BudgetInput, @ActorUserID;

            SET @Message = N'Annual budget saved.';
        END

        /* 
           APPROVAL AND REJECTION
            */

        ELSE IF @Action = 'ApprovePO'
        BEGIN
            EXEC dbo.usp_Purchasing_ApprovePO @POID, @ActorUserID;
            SET @Message = N'PO approved.';
        END

        ELSE IF @Action = 'RejectPO'
        BEGIN
            IF @Notes IS NULL
                THROW 50515, 'A rejection reason is required.', 1;

            UPDATE dbo.PURCHASE_ORDERS
            SET Status = 'Rejected'
            WHERE POID = @POID AND Status = 'Pending Approval';

            IF @@ROWCOUNT <> 1
                THROW 50516, 'Only a pending PO can be rejected.', 1;

            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.PURCHASING_PO_TRACKING WHERE POID = @POID
            )
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DecisionReason = @Notes WHERE POID = @POID;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Rejected'
            WHERE PRID =
                (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID)
               OR PRID IN
                (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID);

            INSERT INTO dbo.NOTIFICATIONS
            (
                RecipientUserID, NotificationType, Title, Message,
                RelatedEntityType, RelatedEntityID, IsRead, CreatedAt
            )
            SELECT DISTINCT
                pr.CreatedByUserID, 'PO_REJECTED',
                'Purchase order rejected', @Notes,
                'PURCHASE_ORDER', @POID, 0, SYSDATETIME()
            FROM dbo.PURCHASE_REQUESTS pr
            WHERE pr.PRID =
                (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID)
               OR pr.PRID IN
                (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID);

            SET @Message = N'PO rejected and Purchasing notified.';
        END

        ELSE IF @Action = 'RevisePR'
        BEGIN
            IF EXISTS
            (
                SELECT 1 FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1 FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50517, 'A PR with an active PO cannot be reopened.', 1;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Open'
            WHERE PRID = @PRID AND Status = 'Rejected';

            IF @@ROWCOUNT <> 1
                THROW 50517, 'Only a rejected PR can be reopened.', 1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0 WHERE PRID = @PRID;

            SET @Message = N'PR reopened. Update quotations and compare again.';
        END

        /* 
           RECORD SUPPLIER DISPATCH
          */

        ELSE IF @Action = 'DispatchPO'
        BEGIN
            UPDATE po
            SET Status = 'Sent to Supplier'
            FROM dbo.PURCHASE_ORDERS po
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
            WHERE po.POID = @POID
              AND po.Status = 'Approved'
              AND s.IsActive = 1;

            IF @@ROWCOUNT <> 1
                THROW 50518, 'Only an approved PO for an active supplier can be dispatched.', 1;

            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.PURCHASING_PO_TRACKING WHERE POID = @POID
            )
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DispatchedAt = SYSDATETIME()
            WHERE POID = @POID;

            SET @Message = N'Supplier dispatch recorded.';
        END

        /* 
           SUPPLIER DELIVERY INSPECTION
           This records the DR only. It does not add stock.
           */

        ELSE IF @Action = 'RecordDR'
        BEGIN
            SELECT
                @ItemID = ItemID,
                @Outstanding = OutstandingQuantity,
                @Status = Status
            FROM dbo.vw_PurchasingWorkspacePO
            WHERE POID = @POID;

            IF @Status IS NULL
               OR @Status NOT IN ('Sent to Supplier', 'Partially Delivered')
                THROW 50519, 'Select a dispatched PO with outstanding quantities.', 1;

            IF @DRNumber IS NULL
                THROW 50520, 'Enter the supplier DR number.', 1;

            IF @Delivered IS NULL OR @Accepted IS NULL OR @Rejected IS NULL
               OR @Delivered <= 0 OR @Accepted < 0 OR @Rejected < 0
               OR CONVERT(BIGINT, @Accepted) + @Rejected <> @Delivered
               OR @Accepted > @Outstanding
                THROW 50521, 'Check delivered, accepted, rejected, and outstanding quantities.', 1;

            IF @Rejected > 0 AND @Notes IS NULL
                THROW 50522, 'Describe the damaged or rejected items.', 1;

            IF EXISTS
            (
                SELECT 1 FROM dbo.PURCHASING_DR_TRACKING
                WHERE POID = @POID AND SupplierDRNumber = @DRNumber
            )
                THROW 50523, 'That supplier DR is already recorded for this PO.', 1;

            INSERT INTO dbo.DELIVERY_RECEIPTS (POID, Status, Notes)
            VALUES
            (
                @POID,
                CASE
                    WHEN @Accepted = 0 THEN 'Rejected'
                    WHEN @Rejected > 0 THEN 'With Discrepancies'
                    ELSE 'Accepted'
                END,
                @Notes
            );

            SET @DRID = SCOPE_IDENTITY();
            SET @ResultID = @DRID;

            INSERT INTO dbo.DELIVERY_RECEIPT_DETAILS
            (
                DRID, ItemID, QuantityDelivered,
                QuantityAccepted, QuantityRejected, Remarks
            )
            VALUES
            (
                @DRID, @ItemID, @Delivered,
                @Accepted, @Rejected, LEFT(@Notes, 500)
            );

            INSERT INTO dbo.PURCHASING_DR_TRACKING
            (
                DRID, POID, SupplierDRNumber, RecordedByUserID
            )
            VALUES
            (
                @DRID, @POID, @DRNumber, @ActorUserID
            );

            INSERT INTO dbo.NOTIFICATIONS
            (
                RecipientUserID, NotificationType, Title, Message,
                RelatedEntityType, RelatedEntityID, IsRead, CreatedAt
            )
            SELECT DISTINCT
                u.UserID, 'PURCHASE_DELIVERY',
                'Supplier delivery checked',
                CONCAT(
                    'PO #', @POID, ', DR #', @DRID,
                    ': ', @Accepted,
                    ' accepted. Process this checked DR through Receiving.'
                ),
                'DELIVERY_RECEIPT', @DRID, 0, SYSDATETIME()
            FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.IsActive = 1
              AND p.PermissionCode = 'receiving.manage'
              AND @Accepted > 0;

            SET @Message = N'DR recorded. Accepted items await checked-DR receiving.';
        END

        ELSE IF @Action = 'ReplacementSent'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.DELIVERY_RECEIPT_DETAILS
                WHERE DRID = @DRID AND QuantityRejected > 0
            )
                THROW 50524, 'This DR has no rejected items.', 1;

            UPDATE dbo.PURCHASING_DR_TRACKING
            SET ReplacementRequestedAt = SYSDATETIME()
            WHERE DRID = @DRID AND ReplacementRequestedAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50524, 'Replacement request already recorded or DR unavailable.', 1;

            SET @Message = N'Supplier replacement request recorded.';
        END

        ELSE IF @Action = 'FollowupSent'
        BEGIN
            UPDATE dbo.PURCHASING_FOLLOWUPS
            SET SentAt = SYSDATETIME(), SentByUserID = @ActorUserID
            WHERE FollowupID = @FollowupID AND SentAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50525, 'Follow-up already marked sent or unavailable.', 1;

            SET @Message = N'Follow-up marked sent.';
        END

        ELSE
            THROW 50526, 'Unknown purchasing action.', 1;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID, @ActorUserID, 'PURCHASING_ACTION',
            CONCAT(
                @Action, '; PR=', @PRID,
                '; PO=', @POID, '; ', @Message
            )
        );

        COMMIT TRANSACTION;

        SELECT @ResultID AS ID, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   6. RECEIVING INTEGRATION FOR CHECKED SUPPLIER DRs

   Receiving developer calls this procedure using:
       @ActorUserID = authenticated receiving user
       @DRID        = checked supplier DR

   It calls V011's receiving procedure exactly once.
   It does not call usp_Inventory_UpdateFromDelivery afterward.
  */

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
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'receiving.manage'
    )
        THROW 50530, 'Receiving management permission is required.', 1;

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

        -- If the RepF was received separately, stop instead of
        -- adding the same supplier delivery to stock again.
        IF @ActualReceived IS NULL
           OR @ActualReceived <> @Baseline + @PriorApplied
            THROW 50533, 'This replenishment has receipts outside the checked-DR workflow. Reconcile them before receiving this DR.', 1;

        IF @PriorApplied + @Accepted > @Ordered
            THROW 50534, 'Receiving would exceed the PO quantity.', 1;

        SET @Remarks = CONCAT(
            'Accepted supplier delivery: PO #', @POID,
            ', DR #', @DRID, '.'
        );

        -- Create the RM record, then let V011 update stock and
        -- reservations. Everything stays in the same outer transaction.
        INSERT INTO dbo.RECEIVING_MEMOS
        (
            DRID, ReceivedByUserID, Remarks, InventoryUpdated
        )
        VALUES
        (
            @DRID, @ActorUserID, @Remarks, 0
        );

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

        -- Already applied by V011. Do not run the older stock engine.
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

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID, @ActorUserID, 'PURCHASE_DR_RECEIVED',
            CONCAT(
                'DR #', @DRID, ' received through RM #', @RMID,
                '. Quantity: ', @Accepted, '.'
            )
        );

        COMMIT TRANSACTION;

        SELECT @RMID AS RMID,
               N'Checked delivery received and inventory updated.' AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   7. PURCHASING WORKSPACE DATA

   Result order matches PurchasingRepository.Load().
   */

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
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('purchasing.view', 'purchasing.manage')
    )
        THROW 50501, 'You do not have permission to view Purchasing.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'purchasing.manage'
    )
        SET @Manage = 1;

    SELECT
        @Approve = CASE
            WHEN r.RoleName IN ('Admin', 'Manager') THEN 1 ELSE 0 END,
        @Admin = CASE WHEN r.RoleName = 'Admin' THEN 1 ELSE 0 END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    -- Generate one supplier follow-up draft per due PO per day.
    -- Draft generation happens on workspace load/refresh.
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
                THROW 50502, 'Purchasing is busy. Please refresh again.', 1;

            INSERT INTO dbo.PURCHASING_FOLLOWUPS
                (POID, ReminderDate, Message)
            SELECT
                po.POID,
                CAST(SYSDATETIME() AS DATE),
                CONCAT(
                    'Please follow up PO #', po.POID,
                    ' for ', po.ItemName,
                    '. Outstanding supplier quantity: ',
                    po.OutstandingQuantity,
                    '. Expected date: ',
                    CONVERT(VARCHAR(10), po.ExpectedDate, 23), '.'
                )
            FROM dbo.vw_PurchasingWorkspacePO po
            WHERE po.Status IN ('Sent to Supplier', 'Partially Delivered')
              AND po.OutstandingQuantity > 0
              AND po.ExpectedDate <= CAST(SYSDATETIME() AS DATE)
              AND NOT EXISTS
              (
                  SELECT 1 FROM dbo.PURCHASING_FOLLOWUPS f
                  WHERE f.POID = po.POID
                    AND f.ReminderDate = CAST(SYSDATETIME() AS DATE)
              );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH;
    END;

    -- Result 1: action permissions.
    SELECT @Manage AS CanManage,
           @Approve AS CanApprove,
           @Admin AS CanSetBudget;

    -- Result 2: pending replenishments without a PR.
    -- QuantityNeeded is aliased to remaining quantity for the existing UI.
    SELECT
        rr.RepFID,
        i.ItemCode,
        i.ItemName,
        rr.QuantityNeeded - rr.QuantityReceived AS QuantityNeeded,
        rr.QuantityReceived,
        rr.OriginRequisitionID
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
    WHERE rr.Status = 'Pending'
      AND rr.QuantityNeeded > rr.QuantityReceived
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.PURCHASE_REQUESTS pr
          WHERE pr.RepFID = rr.RepFID
      )
    ORDER BY rr.DateGenerated, rr.RepFID;

    -- Result 3: PRs.
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
        pr.DateCreated
    FROM dbo.PURCHASE_REQUESTS pr
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
    ORDER BY pr.PRID DESC;

    -- Result 4: quotations.
    SELECT
        q.QuotationID, q.PRID, q.SupplierID,
        s.SupplierName, s.IsActive,
        q.QuotedPrice, q.IsRecommended
    FROM dbo.SUPPLIER_QUOTATIONS q
    INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
    ORDER BY q.PRID, q.QuotedPrice, q.QuotationID;

    -- Result 5: suppliers.
    SELECT SupplierID, SupplierName, Email, IsActive
    FROM dbo.SUPPLIERS
    ORDER BY SupplierName;

    -- Result 6: purchase orders.
    SELECT *
    FROM dbo.vw_PurchasingWorkspacePO
    ORDER BY POID DESC;

    -- Result 7: budgets.
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
              'Approved', 'Sent to Supplier',
              'Partially Delivered', 'Delivered'
          )
    ) c
    WHERE b.IsActive = 1
    ORDER BY b.BudgetYear DESC;

    -- Result 8: DR checks and Receiving Memo status.
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
    LEFT JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
    LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS d ON d.DRID = dr.DRID
    LEFT JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
    ORDER BY dr.DRID DESC;

    -- Result 9: follow-up drafts and sent history.
    SELECT f.*, s.SupplierName, s.Email
    FROM dbo.PURCHASING_FOLLOWUPS f
    INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = f.POID
    INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
    ORDER BY f.FollowupID DESC;
END;
GO

/*
   8. CHECKED-DR RECEIVING QUEUE FOR THE RECEIVING DEVELOPER

   These rows should be processed using:
       dbo.usp_Purchasing_ReceiveCheckedDR

   They must not also be received manually through the direct RepF
   receiving form.
    */

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