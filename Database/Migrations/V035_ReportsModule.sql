USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* 
   1. PERMISSIONS & ROLE GRANTS
    */

IF NOT EXISTS (SELECT 1 FROM dbo.PERMISSIONS WHERE PermissionCode = 'reports.view')
    INSERT INTO dbo.PERMISSIONS (PermissionCode, Description)
    VALUES ('reports.view', N'View system reports');

IF NOT EXISTS (SELECT 1 FROM dbo.PERMISSIONS WHERE PermissionCode = 'reports.export')
    INSERT INTO dbo.PERMISSIONS (PermissionCode, Description)
    VALUES ('reports.export', N'Print and export system reports');

IF NOT EXISTS (SELECT 1 FROM dbo.PERMISSIONS WHERE PermissionCode = 'reports.audit')
    INSERT INTO dbo.PERMISSIONS (PermissionCode, Description)
    VALUES ('reports.audit', N'View sensitive audit and security reports');
GO

/* Grant reports.view to all active roles (Staff sees own-scoped records only). */
INSERT INTO dbo.ROLE_PERMISSIONS (RoleID, PermissionID)
SELECT r.RoleID, p.PermissionID
FROM dbo.ROLES r
CROSS JOIN dbo.PERMISSIONS p
WHERE p.PermissionCode = 'reports.view'
  AND r.RoleName IN (N'Admin', N'Manager', N'Inventory Staff', N'Purchasing Staff', N'Staff')
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.ROLE_PERMISSIONS rp
      WHERE rp.RoleID = r.RoleID AND rp.PermissionID = p.PermissionID
  );

/* Grant reports.export to operational & management roles. */
INSERT INTO dbo.ROLE_PERMISSIONS (RoleID, PermissionID)
SELECT r.RoleID, p.PermissionID
FROM dbo.ROLES r
CROSS JOIN dbo.PERMISSIONS p
WHERE p.PermissionCode = 'reports.export'
  AND r.RoleName IN (N'Admin', N'Manager', N'Inventory Staff', N'Purchasing Staff')
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.ROLE_PERMISSIONS rp
      WHERE rp.RoleID = r.RoleID AND rp.PermissionID = p.PermissionID
  );

/* Grant reports.audit to Admin and Manager only. */
INSERT INTO dbo.ROLE_PERMISSIONS (RoleID, PermissionID)
SELECT r.RoleID, p.PermissionID
FROM dbo.ROLES r
CROSS JOIN dbo.PERMISSIONS p
WHERE p.PermissionCode = 'reports.audit'
  AND r.RoleName IN (N'Admin', N'Manager')
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.ROLE_PERMISSIONS rp
      WHERE rp.RoleID = r.RoleID AND rp.PermissionID = p.PermissionID
  );
GO

/* 
   2. REPORT AUDIT LOGS TABLE
 */

IF OBJECT_ID(N'dbo.REPORT_AUDIT_LOGS', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.REPORT_AUDIT_LOGS
    (
        ReportAuditID BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_REPORT_AUDIT_LOGS PRIMARY KEY,
        ActorUserID INT NOT NULL,
        ActorRole NVARCHAR(100) NOT NULL,
        ReportCode VARCHAR(60) NOT NULL,
        ActionType VARCHAR(30) NOT NULL,
        FilterSummary NVARCHAR(1000) NULL,
        [RowCount] INT NULL,
        CreatedAt DATETIME2(0) NOT NULL
            CONSTRAINT DF_REPORT_AUDIT_LOGS_CreatedAt DEFAULT (SYSDATETIME())
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_REPORT_AUDIT_LOGS_Actor'
)
    ALTER TABLE dbo.REPORT_AUDIT_LOGS
        ADD CONSTRAINT FK_REPORT_AUDIT_LOGS_Actor
        FOREIGN KEY (ActorUserID) REFERENCES dbo.USERS (UserID);
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_REPORT_AUDIT_LOGS_CreatedAt'
      AND object_id = OBJECT_ID(N'dbo.REPORT_AUDIT_LOGS')
)
    CREATE INDEX IX_REPORT_AUDIT_LOGS_CreatedAt
        ON dbo.REPORT_AUDIT_LOGS (CreatedAt DESC);
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_REPORT_AUDIT_LOGS_CodeDate'
      AND object_id = OBJECT_ID(N'dbo.REPORT_AUDIT_LOGS')
)
    CREATE INDEX IX_REPORT_AUDIT_LOGS_CodeDate
        ON dbo.REPORT_AUDIT_LOGS (ReportCode, CreatedAt DESC);
GO

/* 
   3. REPORT AUDIT LOGGER
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_LogAction
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @ActionType VARCHAR(30),
    @FilterSummary NVARCHAR(1000) = NULL,
    @RowCount INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActorRole NVARCHAR(100);

    SELECT @ActorRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF @ActorRole IS NULL
        RETURN;

    INSERT INTO dbo.REPORT_AUDIT_LOGS
    (
        ActorUserID, ActorRole, ReportCode, ActionType,
        FilterSummary, [RowCount], CreatedAt
    )
    VALUES
    (
        @ActorUserID, @ActorRole, LEFT(@ReportCode, 60),
        LEFT(@ActionType, 30), LEFT(@FilterSummary, 1000),
        @RowCount, SYSDATETIME()
    );

    IF @ActionType IN ('PRINT', 'EXPORT_CSV', 'EXPORT_EXCEL', 'DOC_PRINT')
    BEGIN
        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID,
            @ActorUserID,
            'REPORT_' + LEFT(@ActionType, 20),
            CONCAT(
                @ActionType, ' ', @ReportCode,
                CASE WHEN @RowCount IS NOT NULL THEN CONCAT(' (', @RowCount, ' rows)') ELSE '' END,
                CASE WHEN NULLIF(@FilterSummary, N'') IS NOT NULL THEN CONCAT(' | ', LEFT(@FilterSummary, 250)) ELSE '' END
            )
        );
    END
END;
GO

/* 
   4. FILTER OPTIONS & ACTOR CONTEXT (1 DB CALL ON PAGE LOAD)
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_GetFilterOptions
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RoleName NVARCHAR(100),
        @CanView BIT = 0,
        @CanExport BIT = 0,
        @CanAudit BIT = 0;

    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF @RoleName IS NULL
        THROW 50800, 'Your session is no longer active.', 1;

    SELECT
        @CanView = MAX(CASE WHEN p.PermissionCode = 'reports.view' THEN 1 ELSE 0 END),
        @CanExport = MAX(CASE WHEN p.PermissionCode = 'reports.export' THEN 1 ELSE 0 END),
        @CanAudit = MAX(CASE WHEN p.PermissionCode = 'reports.audit' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID;

    IF ISNULL(@CanView, 0) = 0
        THROW 50801, 'You do not have permission to view reports.', 1;

    /* RS1: context & branding */
    SELECT
        @RoleName AS ActorRole,
        CAST(ISNULL(@CanExport, 0) AS BIT) AS CanExport,
        CAST(ISNULL(@CanAudit, 0) AS BIT) AS CanAudit,
        (SELECT SettingValue FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'SalonName') AS SalonName,
        (SELECT SettingValue FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'SalonTagline') AS SalonTagline;

    /* RS2: categories */
    SELECT CategoryID, CategoryName
    FROM dbo.CATEGORIES
    WHERE IsActive = 1
    ORDER BY CategoryName;

    /* RS3: items */
    SELECT ItemID, ItemCode, ItemName, CategoryID
    FROM dbo.ITEMS
    ORDER BY ItemName;

    /* RS4: suppliers */
    SELECT SupplierID, SupplierCode, SupplierName
    FROM dbo.SUPPLIERS
    ORDER BY SupplierName;

    /* RS5: users/requestors (row-scoped for Staff) */
    SELECT
        u.UserID,
        LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))) AS FullName,
        r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE (@RoleName <> N'Staff' OR u.UserID = @ActorUserID)
    ORDER BY u.FirstName, u.LastName;

    /* RS6: roles (department/role filter) */
    SELECT RoleID, RoleName
    FROM dbo.ROLES
    WHERE IsActive = 1
    ORDER BY RoleName;
END;
GO

/* 
   5. INVENTORY REPORTS
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Inventory
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @AsOfDate DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    DECLARE @HasAccess BIT = 0;

    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND p.PermissionCode = 'reports.view'
    )
    AND (
        @RoleName IN (N'Admin', N'Manager')
        OR EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID
              AND p.PermissionCode IN ('inventory.view', 'receiving.view', 'purchasing.view')
        )
    )
        SET @HasAccess = 1;

    IF @HasAccess = 0
        THROW 50802, 'You do not have permission to view inventory reports.', 1;

    DECLARE @EffectiveTo DATETIME2(0) =
        CASE
            WHEN @AsOfDate IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@AsOfDate AS DATETIME2(0)))
            WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0)))
            ELSE NULL
        END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; AsOf=', ISNULL(CONVERT(VARCHAR(10), @AsOfDate, 23), 'Current'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; CategoryID=', ISNULL(CAST(@CategoryID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('INV_STOCK_CARD', 'INV_MOVEMENT_LEDGER', 'INV_ADJUSTMENTS')
    BEGIN
        DECLARE @Movements TABLE
        (
            InventoryLogID BIGINT,
            TransactionDate DATETIME2(0),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            UnitOfMeasure NVARCHAR(40),
            TransactionType VARCHAR(40),
            ReferenceDisplay VARCHAR(40),
            SourceDisplay VARCHAR(30),
            PreviousQuantity INT,
            QuantityChange INT,
            NewQuantity INT,
            ActorName NVARCHAR(200),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Movements
        SELECT
            l.InventoryLogID,
            l.TransactionDate,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.UnitOfMeasure,
            l.TransactionType,
            CASE l.ReferenceType
                WHEN 'RECEIVING' THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'REPLENISHMENT' THEN 'RepF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'DELIVERY' THEN 'AR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'REQUISITION' THEN 'RF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'ADJUSTMENT' THEN 'ADJ-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'PURCHASE' THEN 'PO-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                ELSE N'—'
            END,
            CASE l.ReferenceType
                WHEN 'RECEIVING' THEN 'Receiving'
                WHEN 'REPLENISHMENT' THEN 'Replenishment'
                WHEN 'DELIVERY' THEN 'Issuance'
                WHEN 'REQUISITION' THEN 'Requisition'
                WHEN 'ADJUSTMENT' THEN 'Adjustment'
                WHEN 'PURCHASE' THEN 'Purchase'
                ELSE 'System'
            END,
            l.PreviousQuantity,
            l.QuantityChange,
            l.NewQuantity,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            l.Remarks
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.ITEMS i ON i.ItemID = l.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.USERS u ON u.UserID = l.UserID
        WHERE (@ItemID IS NULL OR l.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (@DateFrom IS NULL OR l.TransactionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@EffectiveTo IS NULL OR l.TransactionDate <= @EffectiveTo)
          AND (
              @ReportCode <> 'INV_ADJUSTMENTS'
              OR l.TransactionType = 'Adjustment'
              OR l.ReferenceType = 'ADJUSTMENT'
          )
          AND (NULLIF(@Status, '') IS NULL OR l.TransactionType = @Status);

        SELECT @RowCount = COUNT(*) FROM @Movements;

        /* RS1: Summary */
        SELECT
            @RowCount AS TotalMovements,
            ISNULL(SUM(CASE WHEN QuantityChange > 0 THEN QuantityChange ELSE 0 END), 0) AS TotalStockIn,
            ISNULL(SUM(CASE WHEN QuantityChange < 0 THEN -QuantityChange ELSE 0 END), 0) AS TotalStockOut,
            ISNULL(SUM(QuantityChange), 0) AS NetChange
        FROM @Movements;

        /* RS2: Details */
        SELECT *
        FROM @Movements
        ORDER BY
            CASE WHEN @ReportCode = 'INV_STOCK_CARD' THEN TransactionDate END ASC,
            CASE WHEN @ReportCode = 'INV_STOCK_CARD' THEN InventoryLogID END ASC,
            TransactionDate DESC,
            InventoryLogID DESC;
    END
    ELSE IF @ReportCode IN ('INV_STOCK_POSITION', 'INV_LOW_STOCK')
    BEGIN
        /* Historical As-Of reconstruction: roll back logs strictly after @AsOfDate end-of-day. */
        DECLARE @AsOfEnd DATETIME2(0) =
            CASE WHEN @AsOfDate IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@AsOfDate AS DATETIME2(0))) ELSE NULL END;

        DECLARE @Positions TABLE
        (
            ItemID INT,
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            UnitOfMeasure NVARCHAR(40),
            UnitPrice DECIMAL(18,2),
            ReorderPoint INT,
            QuantityOnHand INT,
            QuantityReserved INT,
            QuantityAvailable INT,
            InventoryValue DECIMAL(18,2),
            StockStatus VARCHAR(30),
            SuggestedReorder INT,
            LastUpdated DATETIME2(0)
        );

        INSERT INTO @Positions
        SELECT
            i.ItemID,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.UnitOfMeasure,
            i.UnitPrice,
            i.ReorderPoint,
            pos.OnHandAsOf,
            pos.ReservedQty,
            pos.AvailableAsOf,
            CAST(pos.OnHandAsOf AS DECIMAL(18,2)) * i.UnitPrice,
            CASE
                WHEN i.IsActive = 0 THEN 'Inactive'
                WHEN pos.OnHandAsOf <= 0 THEN 'No stock'
                WHEN pos.AvailableAsOf <= 0 THEN 'Fully reserved'
                WHEN pos.AvailableAsOf <= i.ReorderPoint THEN 'Low stock'
                ELSE 'OK'
            END,
            CASE
                WHEN pos.AvailableAsOf <= i.ReorderPoint
                    THEN (i.ReorderPoint - pos.AvailableAsOf) + CASE WHEN i.ReorderPoint > 0 THEN i.ReorderPoint ELSE 5 END
                ELSE 0
            END,
            inv.LastUpdated
        FROM dbo.ITEMS i
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.INVENTORY inv ON inv.ItemID = i.ItemID
        OUTER APPLY
        (
            SELECT ISNULL(SUM(l.QuantityChange), 0) AS DeltaAfterAsOf
            FROM dbo.INVENTORY_LOGS l
            WHERE @AsOfEnd IS NOT NULL
              AND l.ItemID = i.ItemID
              AND l.TransactionDate > @AsOfEnd
        ) afterLogs
        CROSS APPLY
        (
            SELECT
                CASE
                    WHEN ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf < 0 THEN 0
                    ELSE ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf
                END AS OnHandAsOf,
                ISNULL(inv.QuantityReserved, 0) AS ReservedQty,
                (
                    CASE
                        WHEN ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf < 0 THEN 0
                        ELSE ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf
                    END - ISNULL(inv.QuantityReserved, 0)
                ) AS AvailableAsOf
        ) pos
        WHERE (@ItemID IS NULL OR i.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (
              @ReportCode <> 'INV_LOW_STOCK'
              OR (i.IsActive = 1 AND (pos.OnHandAsOf <= 0 OR pos.AvailableAsOf <= i.ReorderPoint))
          )
          AND (
              NULLIF(@Status, '') IS NULL
              OR (
                  CASE
                      WHEN i.IsActive = 0 THEN 'Inactive'
                      WHEN pos.OnHandAsOf <= 0 THEN 'No stock'
                      WHEN pos.AvailableAsOf <= 0 THEN 'Fully reserved'
                      WHEN pos.AvailableAsOf <= i.ReorderPoint THEN 'Low stock'
                      ELSE 'OK'
                  END
              ) = @Status
          );

        SELECT @RowCount = COUNT(*) FROM @Positions;

        /* RS1: Summary */
        SELECT
            @RowCount AS TotalItems,
            ISNULL(SUM(QuantityOnHand), 0) AS TotalOnHand,
            ISNULL(SUM(QuantityReserved), 0) AS TotalReserved,
            ISNULL(SUM(QuantityAvailable), 0) AS TotalAvailable,
            ISNULL(SUM(InventoryValue), 0) AS TotalValuation,
            ISNULL(SUM(CASE WHEN StockStatus IN ('Low stock', 'No stock', 'Fully reserved') THEN 1 ELSE 0 END), 0) AS LowOrOutCount
        FROM @Positions;

        /* RS2: Details */
        SELECT
            ItemCode,
            ItemName,
            CategoryName,
            UnitOfMeasure,
            QuantityOnHand,
            QuantityReserved,
            QuantityAvailable,
            ReorderPoint,
            UnitPrice,
            InventoryValue,
            StockStatus,
            SuggestedReorder,
            LastUpdated
        FROM @Positions
        ORDER BY
            CASE WHEN @ReportCode = 'INV_LOW_STOCK' THEN QuantityAvailable END ASC,
            ItemName ASC;
    END
    ELSE
        THROW 50809, 'Unknown inventory report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   6. PURCHASING REPORTS
  */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Purchasing
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @SupplierID INT = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('purchasing.view', 'purchasing.manage')
        )
    )
        THROW 50803, 'You do not have permission to view purchasing reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; SupplierID=', ISNULL(CAST(@SupplierID AS VARCHAR(20)), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('PUR_PO_REGISTER', 'PUR_PO_OUTSTANDING')
    BEGIN
        DECLARE @POs TABLE
        (
            POID INT,
            POCode VARCHAR(20),
            PRCode VARCHAR(20),
            RepFCode VARCHAR(20),
            DateIssued DATETIME2(0),
            ExpectedDate DATE,
            DispatchedAt DATETIME2(0),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            QuantityOrdered INT,
            AcceptedQuantity INT,
            StockedQuantity INT,
            OutstandingQuantity INT,
            UnitPrice DECIMAL(18,2),
            TotalAmount DECIMAL(18,2),
            Status VARCHAR(30),
            ApprovedByName NVARCHAR(200),
            IsOverdue VARCHAR(10)
        );

        INSERT INTO @POs
        SELECT
            po.POID,
            'PO-' + RIGHT('0000' + CAST(po.POID AS VARCHAR(10)), 4),
            'PR-' + RIGHT('0000' + CAST(po.PRID AS VARCHAR(10)), 4),
            'RepF-' + RIGHT('0000' + CAST(rr.RepFID AS VARCHAR(10)), 4),
            po.DateIssued,
            t.ExpectedDate,
            t.DispatchedAt,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            po.QuantityOrdered,
            ISNULL(a.AcceptedQty, 0),
            ISNULL(m.StockedQty, 0),
            po.QuantityOrdered - ISNULL(a.AcceptedQty, 0),
            po.UnitPrice,
            po.TotalAmount,
            po.Status,
            LTRIM(RTRIM(CONCAT(ap.FirstName, ' ', ap.LastName))),
            CASE
                WHEN t.ExpectedDate IS NOT NULL
                     AND t.ExpectedDate < CAST(SYSDATETIME() AS DATE)
                     AND (po.QuantityOrdered - ISNULL(a.AcceptedQty, 0)) > 0
                     AND po.Status NOT IN ('Delivered', 'Rejected', 'Cancelled')
                    THEN 'Overdue'
                ELSE 'On Track'
            END
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        LEFT JOIN dbo.PURCHASING_PO_TRACKING t ON t.POID = po.POID
        LEFT JOIN dbo.USERS ap ON ap.UserID = po.ApprovedByUserID
        OUTER APPLY
        (
            SELECT SUM(drd.QuantityAccepted) AS AcceptedQty
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd ON drd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) a
        OUTER APPLY
        (
            SELECT SUM(rmd.QuantityReceived) AS StockedQty
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
            INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
            WHERE dr.POID = po.POID AND rm.InventoryUpdated = 1
        ) m
        WHERE (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status)
          AND (
              @ReportCode <> 'PUR_PO_OUTSTANDING'
              OR (po.Status NOT IN ('Delivered', 'Rejected', 'Cancelled')
                  AND (po.QuantityOrdered - ISNULL(a.AcceptedQty, 0)) > 0)
          );

        SELECT @RowCount = COUNT(*) FROM @POs;

        SELECT
            @RowCount AS TotalPOs,
            ISNULL(SUM(QuantityOrdered), 0) AS TotalOrdered,
            ISNULL(SUM(AcceptedQuantity), 0) AS TotalAccepted,
            ISNULL(SUM(OutstandingQuantity), 0) AS TotalOutstanding,
            ISNULL(SUM(TotalAmount), 0) AS TotalSpend
        FROM @POs;

        SELECT * FROM @POs ORDER BY DateIssued DESC, POID DESC;
    END
    ELSE IF @ReportCode = 'PUR_SUPPLIER_PERF'
    BEGIN
        DECLARE @Perf TABLE
        (
            SupplierCode VARCHAR(30),
            SupplierName NVARCHAR(200),
            TotalPOs INT,
            TotalSpend DECIMAL(18,2),
            TotalOrdered INT,
            TotalDelivered INT,
            TotalAccepted INT,
            TotalRejected INT,
            AcceptanceRatePct DECIMAL(6,2),
            ReturnSlipCount INT
        );

        INSERT INTO @Perf
        SELECT
            s.SupplierCode,
            s.SupplierName,
            COUNT(DISTINCT po.POID),
            ISNULL(SUM(po.TotalAmount), 0),
            ISNULL(SUM(po.QuantityOrdered), 0),
            ISNULL(SUM(drStats.Delivered), 0),
            ISNULL(SUM(drStats.Accepted), 0),
            ISNULL(SUM(drStats.Rejected), 0),
            CASE
                WHEN ISNULL(SUM(drStats.Delivered), 0) > 0
                    THEN CAST(ISNULL(SUM(drStats.Accepted), 0) * 100.0 / SUM(drStats.Delivered) AS DECIMAL(6,2))
                ELSE 0
            END,
            ISNULL(SUM(drStats.RejectedDRs), 0)
        FROM dbo.SUPPLIERS s
        LEFT JOIN dbo.PURCHASE_ORDERS po
            ON po.SupplierID = s.SupplierID
           AND (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
           AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
           AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status)
        OUTER APPLY
        (
            SELECT
                SUM(dd.QuantityDelivered) AS Delivered,
                SUM(dd.QuantityAccepted) AS Accepted,
                SUM(dd.QuantityRejected) AS Rejected,
                COUNT(DISTINCT CASE WHEN dd.QuantityRejected > 0 THEN dr.DRID END) AS RejectedDRs
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) drStats
        WHERE (@SupplierID IS NULL OR s.SupplierID = @SupplierID)
        GROUP BY s.SupplierCode, s.SupplierName
        HAVING COUNT(DISTINCT po.POID) > 0 OR @SupplierID IS NOT NULL;

        SELECT @RowCount = COUNT(*) FROM @Perf;

        SELECT
            @RowCount AS ActiveSuppliers,
            ISNULL(SUM(TotalPOs), 0) AS TotalPOs,
            ISNULL(SUM(TotalSpend), 0) AS TotalSpend,
            ISNULL(SUM(TotalAccepted), 0) AS TotalAccepted,
            ISNULL(SUM(TotalRejected), 0) AS TotalRejected
        FROM @Perf;

        SELECT * FROM @Perf ORDER BY TotalSpend DESC, SupplierName ASC;
    END
    ELSE IF @ReportCode = 'PUR_RETURN_SLIPS'
    BEGIN
        DECLARE @Returns TABLE
        (
            SlipNo VARCHAR(20),
            DeliveryDate DATETIME2(0),
            POCode VARCHAR(20),
            SupplierDRNumber NVARCHAR(100),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            Status VARCHAR(30),
            ReplacementRequestedAt DATETIME2(0),
            RecordedByName NVARCHAR(200),
            Notes NVARCHAR(1000)
        );

        INSERT INTO @Returns
        SELECT
            'RS-' + RIGHT('0000' + CAST(dr.DRID AS VARCHAR(10)), 4),
            dr.DeliveryDate,
            'PO-' + RIGHT('0000' + CAST(dr.POID AS VARCHAR(10)), 4),
            tr.SupplierDRNumber,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            dd.QuantityDelivered,
            dd.QuantityAccepted,
            dd.QuantityRejected,
            dr.Status,
            tr.ReplacementRequestedAt,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            ISNULL(dd.Remarks, dr.Notes)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
        LEFT JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
        LEFT JOIN dbo.USERS u ON u.UserID = tr.RecordedByUserID
        WHERE dd.QuantityRejected > 0
          AND (@DateFrom IS NULL OR dr.DeliveryDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR dr.DeliveryDate <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR dd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR dr.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Returns;

        SELECT
            @RowCount AS TotalReturnSlips,
            ISNULL(SUM(QuantityDelivered), 0) AS TotalDelivered,
            ISNULL(SUM(QuantityRejected), 0) AS TotalRejected,
            ISNULL(SUM(CASE WHEN ReplacementRequestedAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS ReplacementRequestedCount
        FROM @Returns;

        SELECT * FROM @Returns ORDER BY DeliveryDate DESC;
    END
    ELSE IF @ReportCode = 'PUR_QUOTATION_HISTORY'
    BEGIN
        DECLARE @Quotes TABLE
        (
            QuotationID INT,
            DateQuoted DATETIME2(0),
            PRCode VARCHAR(20),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            SupplierName NVARCHAR(200),
            QuotedPrice DECIMAL(18,2),
            Recommended VARCHAR(10),
            PRStatus VARCHAR(30)
        );

        INSERT INTO @Quotes
        SELECT
            q.QuotationID,
            q.DateQuoted,
            'PR-' + RIGHT('0000' + CAST(q.PRID AS VARCHAR(10)), 4),
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            s.SupplierName,
            q.QuotedPrice,
            CASE WHEN q.IsRecommended = 1 THEN 'Yes' ELSE 'No' END,
            pr.Status
        FROM dbo.SUPPLIER_QUOTATIONS q
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = q.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
        WHERE (@DateFrom IS NULL OR q.DateQuoted >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR q.DateQuoted <= @DateToEnd)
          AND (@SupplierID IS NULL OR q.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR pr.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Quotes;

        SELECT
            @RowCount AS TotalQuotations,
            ISNULL(SUM(CASE WHEN Recommended = 'Yes' THEN 1 ELSE 0 END), 0) AS RecommendedCount,
            ISNULL(AVG(QuotedPrice), 0) AS AveragePrice,
            ISNULL(MIN(QuotedPrice), 0) AS LowestPrice,
            ISNULL(MAX(QuotedPrice), 0) AS HighestPrice
        FROM @Quotes;

        SELECT * FROM @Quotes ORDER BY DateQuoted DESC, QuotationID DESC;
    END
    ELSE
        THROW 50809, 'Unknown purchasing report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   7. RECEIVING REPORTS
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Receiving
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @SupplierID INT = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('receiving.view', 'receiving.manage', 'inventory.view')
        )
    )
        THROW 50804, 'You do not have permission to view receiving reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; SupplierID=', ISNULL(CAST(@SupplierID AS VARCHAR(20)), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('REC_RR_REGISTER', 'REC_MANUAL_RECEIPTS')
    BEGIN
        DECLARE @Receipts TABLE
        (
            InventoryLogID BIGINT,
            ReportNo VARCHAR(30),
            TransactionDate DATETIME2(0),
            SourceDisplay VARCHAR(30),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            QuantityReceived INT,
            PreviousQuantity INT,
            NewQuantity INT,
            SupplierName NVARCHAR(200),
            POCode VARCHAR(20),
            ReceivedByName NVARCHAR(200),
            SignedStatus VARCHAR(20),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Receipts
        SELECT
            l.InventoryLogID,
            CASE
                WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                    THEN 'RepF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                ELSE 'RR-' + RIGHT('0000' + CAST(l.InventoryLogID AS VARCHAR(10)), 4)
            END,
            l.TransactionDate,
            CASE WHEN l.ReferenceType = 'REPLENISHMENT' THEN 'Replenishment' ELSE 'Manual receipt' END,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            l.QuantityChange,
            l.PreviousQuantity,
            l.NewQuantity,
            ISNULL(poCtx.SupplierName, N'—'),
            CASE WHEN poCtx.POID IS NOT NULL THEN 'PO-' + RIGHT('0000' + CAST(poCtx.POID AS VARCHAR(10)), 4) ELSE N'—' END,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            CASE WHEN sig.SignatureID IS NOT NULL THEN 'Digitally signed' ELSE 'Unsigned' END,
            l.Remarks
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.ITEMS i ON i.ItemID = l.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.USERS u ON u.UserID = l.UserID
        OUTER APPLY
        (
            SELECT TOP (1) po.POID, po.SupplierID, s.SupplierName
            FROM dbo.PURCHASE_REQUESTS pr
            INNER JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
            WHERE l.ReferenceType = 'REPLENISHMENT' AND pr.RepFID = l.ReferenceID
            ORDER BY po.POID DESC
        ) poCtx
        OUTER APPLY
        (
            SELECT TOP (1) ds.SignatureID
            FROM dbo.DOCUMENT_SIGNATURES ds
            WHERE ds.DocumentType = 'RECEIVING_REPORT'
              AND ds.DocumentID = l.InventoryLogID
              AND ds.Stage = 'Received'
              AND ds.IsActive = 1
        ) sig
        WHERE l.TransactionType = 'Stock In'
          AND (@DateFrom IS NULL OR l.TransactionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR l.TransactionDate <= @DateToEnd)
          AND (@ItemID IS NULL OR l.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (@SupplierID IS NULL OR poCtx.SupplierID = @SupplierID)
          AND (
              @ReportCode <> 'REC_MANUAL_RECEIPTS'
              OR ISNULL(l.ReferenceType, '') <> 'REPLENISHMENT'
          );

        SELECT @RowCount = COUNT(*) FROM @Receipts;

        SELECT
            @RowCount AS TotalReceipts,
            ISNULL(SUM(QuantityReceived), 0) AS TotalQtyReceived,
            ISNULL(SUM(CASE WHEN SourceDisplay = 'Manual receipt' THEN 1 ELSE 0 END), 0) AS ManualCount,
            ISNULL(SUM(CASE WHEN SignedStatus = 'Digitally signed' THEN 1 ELSE 0 END), 0) AS SignedCount
        FROM @Receipts;

        SELECT * FROM @Receipts ORDER BY TransactionDate DESC, InventoryLogID DESC;
    END
    ELSE IF @ReportCode = 'REC_RR_VS_PO'
    BEGIN
        DECLARE @Recon TABLE
        (
            POCode VARCHAR(20),
            DateIssued DATETIME2(0),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            POStatus VARCHAR(30),
            QuantityOrdered INT,
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            QuantityStocked INT,
            PendingToStock INT,
            OrderVariance INT
        );

        INSERT INTO @Recon
        SELECT
            'PO-' + RIGHT('0000' + CAST(po.POID AS VARCHAR(10)), 4),
            po.DateIssued,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            po.Status,
            po.QuantityOrdered,
            ISNULL(d.Delivered, 0),
            ISNULL(d.Accepted, 0),
            ISNULL(d.Rejected, 0),
            ISNULL(m.Stocked, 0),
            ISNULL(d.Accepted, 0) - ISNULL(m.Stocked, 0),
            po.QuantityOrdered - ISNULL(m.Stocked, 0)
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        OUTER APPLY
        (
            SELECT
                SUM(dd.QuantityDelivered) AS Delivered,
                SUM(dd.QuantityAccepted) AS Accepted,
                SUM(dd.QuantityRejected) AS Rejected
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) d
        OUTER APPLY
        (
            SELECT SUM(rmd.QuantityReceived) AS Stocked
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
            INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
            WHERE dr.POID = po.POID AND rm.InventoryUpdated = 1
        ) m
        WHERE po.Status NOT IN ('Rejected', 'Cancelled')
          AND (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Recon;

        SELECT
            @RowCount AS TotalPOs,
            ISNULL(SUM(QuantityOrdered), 0) AS TotalOrdered,
            ISNULL(SUM(QuantityAccepted), 0) AS TotalAccepted,
            ISNULL(SUM(QuantityStocked), 0) AS TotalStocked,
            ISNULL(SUM(OrderVariance), 0) AS TotalVariance
        FROM @Recon;

        SELECT * FROM @Recon ORDER BY DateIssued DESC;
    END
    ELSE IF @ReportCode = 'REC_REJECTED_ITEMS'
    BEGIN
        DECLARE @Rej TABLE
        (
            DRCode VARCHAR(20),
            DeliveryDate DATETIME2(0),
            POCode VARCHAR(20),
            SupplierDRNumber NVARCHAR(100),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            DRStatus VARCHAR(30),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Rej
        SELECT
            'DR-' + RIGHT('0000' + CAST(dr.DRID AS VARCHAR(10)), 4),
            dr.DeliveryDate,
            'PO-' + RIGHT('0000' + CAST(dr.POID AS VARCHAR(10)), 4),
            tr.SupplierDRNumber,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            dd.QuantityDelivered,
            dd.QuantityAccepted,
            dd.QuantityRejected,
            dr.Status,
            ISNULL(dd.Remarks, dr.Notes)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
        LEFT JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
        WHERE dd.QuantityRejected > 0
          AND (@DateFrom IS NULL OR dr.DeliveryDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR dr.DeliveryDate <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR dd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID);

        SELECT @RowCount = COUNT(*) FROM @Rej;

        SELECT
            @RowCount AS RejectedLines,
            ISNULL(SUM(QuantityDelivered), 0) AS TotalDelivered,
            ISNULL(SUM(QuantityRejected), 0) AS TotalRejected
        FROM @Rej;

        SELECT * FROM @Rej ORDER BY DeliveryDate DESC;
    END
    ELSE
        THROW 50809, 'Unknown receiving report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   8. REQUISITION REPORTS (ROW-LEVEL SCOPED)
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Requisition
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL,
    @DepartmentRole NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
        THROW 50805, 'You do not have permission to view requisition reports.', 1;

    /* Row-level scoping: Staff sees only their own requisitions. */
    DECLARE @ScopedRequestorID INT =
        CASE WHEN @RoleName = N'Staff' THEN @ActorUserID ELSE @RequestorUserID END;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; Requestor=', ISNULL(CAST(@ScopedRequestorID AS VARCHAR(20)), 'All'),
        '; Role=', ISNULL(@DepartmentRole, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('REQ_REGISTER', 'REQ_FULFILLMENT_RATE')
    BEGIN
        DECLARE @Reqs TABLE
        (
            RequisitionID INT,
            RFCode VARCHAR(20),
            RequestDate DATETIME2(0),
            RequiredDate DATE,
            RequestorName NVARCHAR(200),
            RequestorRole NVARCHAR(100),
            ApproverName NVARCHAR(200),
            Status VARCHAR(30),
            LineCount INT,
            TotalRequested INT,
            TotalApproved INT,
            TotalFulfilled INT,
            FulfillmentRatePct DECIMAL(6,2),
            ApprovedDate DATETIME2(0),
            Justification NVARCHAR(500)
        );

        INSERT INTO @Reqs
        SELECT
            r.RequisitionID,
            'RF-' + RIGHT('0000' + CAST(r.RequisitionID AS VARCHAR(10)), 4),
            r.RequestDate,
            r.RequiredDate,
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            CASE WHEN ap.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(ap.FirstName, ' ', ap.LastName))) ELSE N'—' END,
            r.Status,
            COUNT(rd.RequisitionDetailID),
            ISNULL(SUM(rd.QuantityRequested), 0),
            ISNULL(SUM(ISNULL(rd.QuantityApproved, 0)), 0),
            ISNULL(SUM(CASE WHEN rd.Status = 'Fulfilled' THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested) ELSE 0 END), 0),
            CASE
                WHEN ISNULL(SUM(rd.QuantityRequested), 0) > 0
                    THEN CAST(ISNULL(SUM(CASE WHEN rd.Status = 'Fulfilled' THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested) ELSE 0 END), 0) * 100.0
                        / SUM(rd.QuantityRequested) AS DECIMAL(6,2))
                ELSE 0
            END,
            r.ApprovedDate,
            r.Justification
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.USERS ap ON ap.UserID = r.DepartmentHeadUserID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (NULLIF(@Status, '') IS NULL OR r.Status = @Status)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY
            r.RequisitionID, r.RequestDate, r.RequiredDate,
            req.FirstName, req.LastName, reqRole.RoleName,
            ap.UserID, ap.FirstName, ap.LastName,
            r.Status, r.ApprovedDate, r.Justification;

        SELECT @RowCount = COUNT(*) FROM @Reqs;

        SELECT
            @RowCount AS TotalRequisitions,
            ISNULL(SUM(TotalRequested), 0) AS TotalRequestedUnits,
            ISNULL(SUM(TotalApproved), 0) AS TotalApprovedUnits,
            ISNULL(SUM(TotalFulfilled), 0) AS TotalFulfilledUnits,
            CASE
                WHEN ISNULL(SUM(TotalRequested), 0) > 0
                    THEN CAST(ISNULL(SUM(TotalFulfilled), 0) * 100.0 / SUM(TotalRequested) AS DECIMAL(6,2))
                ELSE 0
            END AS OverallFulfillmentPct
        FROM @Reqs;

        SELECT * FROM @Reqs ORDER BY RequestDate DESC, RequisitionID DESC;
    END
    ELSE IF @ReportCode = 'REQ_STATUS_SUMMARY'
    BEGIN
        DECLARE @Summary TABLE
        (
            Status VARCHAR(30),
            RequisitionCount INT,
            TotalRequested INT,
            TotalApproved INT,
            SharePct DECIMAL(6,2)
        );

        DECLARE @TotalReqCount INT;
        SELECT @TotalReqCount = COUNT(DISTINCT r.RequisitionID)
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID);

        INSERT INTO @Summary
        SELECT
            r.Status,
            COUNT(DISTINCT r.RequisitionID),
            ISNULL(SUM(rd.QuantityRequested), 0),
            ISNULL(SUM(ISNULL(rd.QuantityApproved, 0)), 0),
            CASE
                WHEN @TotalReqCount > 0
                    THEN CAST(COUNT(DISTINCT r.RequisitionID) * 100.0 / @TotalReqCount AS DECIMAL(6,2))
                ELSE 0
            END
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY r.Status;

        SELECT @RowCount = COUNT(*) FROM @Summary;

        SELECT
            ISNULL(@TotalReqCount, 0) AS TotalRequisitions,
            ISNULL(SUM(TotalRequested), 0) AS TotalRequested,
            ISNULL(SUM(TotalApproved), 0) AS TotalApproved
        FROM @Summary;

        SELECT * FROM @Summary ORDER BY RequisitionCount DESC, Status ASC;
    END
    ELSE IF @ReportCode = 'REQ_REQUESTOR_USAGE'
    BEGIN
        DECLARE @Usage TABLE
        (
            RequestorName NVARCHAR(200),
            DepartmentRole NVARCHAR(100),
            CategoryName NVARCHAR(100),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            RequisitionCount INT,
            QuantityRequested INT,
            QuantityApproved INT,
            EstimatedCost DECIMAL(18,2)
        );

        INSERT INTO @Usage
        SELECT
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.ItemCode,
            i.ItemName,
            COUNT(DISTINCT r.RequisitionID),
            SUM(rd.QuantityRequested),
            SUM(ISNULL(rd.QuantityApproved, 0)),
            SUM(CAST(ISNULL(rd.QuantityApproved, rd.QuantityRequested) AS DECIMAL(18,2)) * i.UnitPrice)
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        WHERE r.Status IN ('Approved', 'Fulfilled')
          AND (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY
            req.FirstName, req.LastName, reqRole.RoleName,
            c.CategoryName, i.ItemCode, i.ItemName;

        SELECT @RowCount = COUNT(*) FROM @Usage;

        SELECT
            @RowCount AS UsageLines,
            ISNULL(SUM(QuantityRequested), 0) AS TotalRequested,
            ISNULL(SUM(QuantityApproved), 0) AS TotalApproved,
            ISNULL(SUM(EstimatedCost), 0) AS TotalEstimatedCost
        FROM @Usage;

        SELECT * FROM @Usage ORDER BY EstimatedCost DESC, RequestorName ASC;
    END
    ELSE
        THROW 50809, 'Unknown requisition report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   9. DELIVERY REPORTS (ROW-LEVEL SCOPED)
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Delivery
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL,
    @DepartmentRole NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
        THROW 50806, 'You do not have permission to view delivery reports.', 1;

    DECLARE @ScopedRequestorID INT =
        CASE WHEN @RoleName = N'Staff' THEN @ActorUserID ELSE @RequestorUserID END;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; Requestor=', ISNULL(CAST(@ScopedRequestorID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('DEL_AR_REGISTER', 'DEL_ISSUED_COMPLETED', 'DEL_DISCREPANCY_CORRECTION')
    BEGIN
        DECLARE @ARs TABLE
        (
            DeliveryID INT,
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            RequestorName NVARCHAR(200),
            RequestorRole NVARCHAR(100),
            Status VARCHAR(30),
            TotalItems INT,
            TotalQuantity INT,
            GeneratedDate DATETIME2(0),
            IssuedDate DATETIME2(0),
            SignedDate DATETIME2(0),
            IssuedByName NVARCHAR(200),
            SignedByName NVARCHAR(200),
            DiscrepancyNotes NVARCHAR(1000),
            CorrectionNotes NVARCHAR(500),
            CorrectedByName NVARCHAR(200),
            CorrectedAt DATETIME2(0)
        );

        INSERT INTO @ARs
        SELECT
            d.DeliveryID,
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            d.Status,
            COUNT(di.DeliveryItemID),
            ISNULL(SUM(di.Quantity), 0),
            d.GeneratedDate,
            d.IssuedDate,
            d.SignedDate,
            CASE WHEN iss.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(iss.FirstName, ' ', iss.LastName))) ELSE N'—' END,
            CASE WHEN sig.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(sig.FirstName, ' ', sig.LastName))) ELSE N'—' END,
            d.DiscrepancyNotes,
            d.CorrectionNotes,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName))) ELSE N'—' END,
            d.CorrectedAt
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.USERS iss ON iss.UserID = d.IssuedByUserID
        LEFT JOIN dbo.USERS sig ON sig.UserID = d.SignedByUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        LEFT JOIN dbo.DELIVERY_ITEMS di ON di.DeliveryID = d.DeliveryID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = di.ItemID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR d.GeneratedDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR d.GeneratedDate <= @DateToEnd)
          AND (NULLIF(@Status, '') IS NULL OR d.Status = @Status)
          AND (@ItemID IS NULL OR di.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (
              @ReportCode <> 'DEL_ISSUED_COMPLETED'
              OR d.Status IN ('Issued', 'Completed')
          )
          AND (
              @ReportCode <> 'DEL_DISCREPANCY_CORRECTION'
              OR (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          )
        GROUP BY
            d.DeliveryID, d.ARCode, d.RequisitionID,
            req.FirstName, req.LastName, reqRole.RoleName,
            d.Status, d.GeneratedDate, d.IssuedDate, d.SignedDate,
            iss.UserID, iss.FirstName, iss.LastName,
            sig.UserID, sig.FirstName, sig.LastName,
            d.DiscrepancyNotes, d.CorrectionNotes,
            cor.UserID, cor.FirstName, cor.LastName, d.CorrectedAt;

        SELECT @RowCount = COUNT(*) FROM @ARs;

        SELECT
            @RowCount AS TotalARs,
            ISNULL(SUM(TotalQuantity), 0) AS TotalDeliveredUnits,
            ISNULL(SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END), 0) AS CompletedCount,
            ISNULL(SUM(CASE WHEN Status = 'Issued' THEN 1 ELSE 0 END), 0) AS IssuedCount,
            ISNULL(SUM(CASE WHEN NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL THEN 1 ELSE 0 END), 0) AS WithDiscrepancyCount
        FROM @ARs;

        SELECT * FROM @ARs ORDER BY GeneratedDate DESC, DeliveryID DESC;
    END
    ELSE IF @ReportCode = 'DEL_SIGNATURE_HISTORY'
    BEGIN
        DECLARE @SigHist TABLE
        (
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            Stage VARCHAR(40),
            SignerName NVARCHAR(200),
            SignerRole NVARCHAR(100),
            SignedAt DATETIME2(0),
            Source VARCHAR(30),
            IntegrityStatus VARCHAR(30)
        );

        INSERT INTO @SigHist
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            h.Stage,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            r.RoleName,
            h.SignedAt,
            'Delivery History',
            'Archived'
        FROM dbo.DELIVERY_SIGNATURE_HISTORY h
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = h.DeliveryID
        INNER JOIN dbo.USERS u ON u.UserID = h.UserID
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR h.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR h.SignedAt <= @DateToEnd)
        UNION ALL
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            ds.SignedAt,
            ds.DocumentType,
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked / Superseded'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Hash Mismatch'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = ds.DocumentID
        WHERE ds.DocumentType IN ('ACKNOWLEDGEMENT_RECEIPT', 'CORRECTION_REPORT')
          AND (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd);

        SELECT @RowCount = COUNT(*) FROM @SigHist;

        SELECT
            @RowCount AS TotalSignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedCount,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS RevokedCount
        FROM @SigHist;

        SELECT * FROM @SigHist ORDER BY SignedAt DESC;
    END
    ELSE
        THROW 50809, 'Unknown delivery report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   10. REPLENISHMENT REPORTS
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Replenishment
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('inventory.view', 'purchasing.view', 'receiving.view')
        )
    )
        THROW 50807, 'You do not have permission to view replenishment reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RepFs TABLE
    (
        RepFID INT,
        RepFCode VARCHAR(20),
        DateGenerated DATETIME2(0),
        ItemCode VARCHAR(30),
        ItemName NVARCHAR(200),
        CategoryName NVARCHAR(100),
        QuantityNeeded INT,
        QuantityReceived INT,
        RemainingQuantity INT,
        Status VARCHAR(30),
        OriginRFCode VARCHAR(20),
        LinkedPRCode VARCHAR(20),
        LinkedPOCode VARCHAR(20),
        POStatus VARCHAR(30),
        SupplierName NVARCHAR(200)
    );

    INSERT INTO @RepFs
    SELECT
        rr.RepFID,
        'RepF-' + RIGHT('0000' + CAST(rr.RepFID AS VARCHAR(10)), 4),
        rr.DateGenerated,
        i.ItemCode,
        i.ItemName,
        ISNULL(c.CategoryName, N'Uncategorized'),
        rr.QuantityNeeded,
        rr.QuantityReceived,
        rr.QuantityNeeded - rr.QuantityReceived,
        rr.Status,
        CASE WHEN rr.OriginRequisitionID IS NOT NULL
             THEN 'RF-' + RIGHT('0000' + CAST(rr.OriginRequisitionID AS VARCHAR(10)), 4)
             ELSE N'Reorder Point' END,
        CASE WHEN link.PRID IS NOT NULL
             THEN 'PR-' + RIGHT('0000' + CAST(link.PRID AS VARCHAR(10)), 4)
             ELSE N'—' END,
        CASE WHEN link.POID IS NOT NULL
             THEN 'PO-' + RIGHT('0000' + CAST(link.POID AS VARCHAR(10)), 4)
             ELSE N'—' END,
        ISNULL(link.POStatus, N'No PO'),
        ISNULL(link.SupplierName, N'—')
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
    LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
    OUTER APPLY
    (
        SELECT TOP (1)
            pr.PRID,
            po.POID,
            po.Status AS POStatus,
            s.SupplierName
        FROM dbo.PURCHASE_REQUESTS pr
        LEFT JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
        LEFT JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        WHERE pr.RepFID = rr.RepFID
        ORDER BY po.POID DESC, pr.PRID DESC
    ) link
    WHERE (@DateFrom IS NULL OR rr.DateGenerated >= CAST(@DateFrom AS DATETIME2(0)))
      AND (@DateToEnd IS NULL OR rr.DateGenerated <= @DateToEnd)
      AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
      AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
      AND (NULLIF(@Status, '') IS NULL OR rr.Status = @Status);

    DECLARE @RowCount INT;
    SELECT @RowCount = COUNT(*) FROM @RepFs;

    SELECT
        @RowCount AS TotalRepFs,
        ISNULL(SUM(CASE WHEN Status = 'Pending' THEN 1 ELSE 0 END), 0) AS PendingCount,
        ISNULL(SUM(CASE WHEN Status = 'Processed' THEN 1 ELSE 0 END), 0) AS ProcessedCount,
        ISNULL(SUM(QuantityNeeded), 0) AS TotalNeeded,
        ISNULL(SUM(RemainingQuantity), 0) AS TotalRemaining
    FROM @RepFs;

    SELECT * FROM @RepFs
    ORDER BY
        CASE WHEN @ReportCode = 'REPF_STATUS_TRACKING' THEN Status END ASC,
        DateGenerated DESC,
        RepFID DESC;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   11. AUDIT & SECURITY REPORTS (REQUIRES reports.audit)
 */

CREATE OR ALTER PROCEDURE dbo.usp_Report_Audit
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'reports.audit'
    )
        THROW 50808, 'You do not have permission to view audit and security reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; UserID=', ISNULL(CAST(@RequestorUserID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode = 'AUD_PRINT_SIGNATURE'
    BEGIN
        DECLARE @SigAudit TABLE
        (
            EventDate DATETIME2(0),
            Category VARCHAR(30),
            DocumentType VARCHAR(60),
            DocumentRef VARCHAR(40),
            StageOrAction VARCHAR(40),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            HashPrefix VARCHAR(20),
            IntegrityStatus VARCHAR(30),
            Details NVARCHAR(500)
        );

        INSERT INTO @SigAudit
        SELECT
            ds.SignedAt,
            'Digital Signature',
            ds.DocumentType,
            CONCAT('#', ds.DocumentID),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            LEFT(ds.DocumentHash, 12),
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Snapshot Changed'
            END,
            CASE
                WHEN ds.IsActive = 0 THEN ISNULL(ds.RevokeReason, N'Revoked')
                ELSE N'Confirmed digital signature'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.SignerUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ds.DocumentType = @Status)
        UNION ALL
        SELECT
            ral.CreatedAt,
            'Report / Print',
            ral.ReportCode,
            CONCAT('LOG-', ral.ReportAuditID),
            ral.ActionType,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            ral.ActorRole,
            N'—',
            'Logged',
            ISNULL(ral.FilterSummary, N'')
        FROM dbo.REPORT_AUDIT_LOGS ral
        INNER JOIN dbo.USERS u ON u.UserID = ral.ActorUserID
        WHERE (@DateFrom IS NULL OR ral.CreatedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ral.CreatedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ral.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ral.ActionType = @Status);

        SELECT @RowCount = COUNT(*) FROM @SigAudit;

        SELECT
            @RowCount AS TotalEvents,
            ISNULL(SUM(CASE WHEN Category = 'Digital Signature' THEN 1 ELSE 0 END), 0) AS SignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedSignatures,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked' THEN 1 ELSE 0 END), 0) AS RevokedSignatures,
            ISNULL(SUM(CASE WHEN Category = 'Report / Print' THEN 1 ELSE 0 END), 0) AS ReportPrintEvents
        FROM @SigAudit;

        SELECT * FROM @SigAudit ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_CORRECTION_HISTORY'
    BEGIN
        DECLARE @CorHist TABLE
        (
            EventDate DATETIME2(0),
            RecordType VARCHAR(40),
            DocumentRef VARCHAR(40),
            ActorName NVARCHAR(200),
            Summary NVARCHAR(1000),
            Status VARCHAR(30)
        );

        INSERT INTO @CorHist
        SELECT
            ISNULL(d.CorrectedAt, d.GeneratedDate),
            'AR Discrepancy / Correction',
            d.ARCode,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName)))
                 ELSE LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))) END,
            CONCAT(
                'Discrepancy: ', ISNULL(d.DiscrepancyNotes, N'—'),
                CASE WHEN d.CorrectionNotes IS NOT NULL THEN CONCAT(' | Correction: ', d.CorrectionNotes) ELSE '' END
            ),
            CASE WHEN d.DiscrepancyResolvedAt IS NOT NULL THEN 'Resolved' WHEN d.CorrectedAt IS NOT NULL THEN 'Corrected' ELSE 'Open' END
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        WHERE (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          AND (@DateFrom IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR d.CorrectedByUserID = @RequestorUserID OR d.RequestorUserID = @RequestorUserID)
        UNION ALL
        SELECT
            ISNULL(ds.RevokedAt, ds.SignedAt),
            'Signature Revoked / Superseded',
            CONCAT(ds.DocumentType, ' #', ds.DocumentID, ' (', ds.Stage, ')'),
            LTRIM(RTRIM(CONCAT(rv.FirstName, ' ', rv.LastName))),
            ISNULL(ds.RevokeReason, N'Revoked'),
            'Revoked'
        FROM dbo.DOCUMENT_SIGNATURES ds
        LEFT JOIN dbo.USERS rv ON rv.UserID = ds.RevokedByUserID
        WHERE ds.IsActive = 0
          AND (@DateFrom IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.RevokedByUserID = @RequestorUserID);

        SELECT @RowCount = COUNT(*) FROM @CorHist;

        SELECT
            @RowCount AS TotalCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'AR Discrepancy / Correction' THEN 1 ELSE 0 END), 0) AS DeliveryCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'Signature Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS SignatureRevocations
        FROM @CorHist;

        SELECT * FROM @CorHist ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_USER_ACTIVITY'
    BEGIN
        DECLARE @Activity TABLE
        (
            AuditID BIGINT,
            ActionDate DATETIME2(0),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            ActionType VARCHAR(60),
            TargetUser NVARCHAR(200),
            Description NVARCHAR(1000)
        );

        INSERT INTO @Activity
        SELECT TOP (1000)
            a.AuditID,
            a.ActionDate,
            LTRIM(RTRIM(CONCAT(actor.FirstName, ' ', actor.LastName))),
            r.RoleName,
            a.ActionType,
            CASE WHEN target.UserID IS NOT NULL
                 THEN LTRIM(RTRIM(CONCAT(target.FirstName, ' ', target.LastName)))
                 ELSE N'—' END,
            a.Description
        FROM dbo.USER_AUDIT_LOGS a
        INNER JOIN dbo.USERS actor ON actor.UserID = a.ActorUserID
        INNER JOIN dbo.ROLES r ON r.RoleID = actor.RoleID
        LEFT JOIN dbo.USERS target ON target.UserID = a.TargetUserID
        WHERE (@DateFrom IS NULL OR a.ActionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR a.ActionDate <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR a.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR a.ActionType = @Status)
        ORDER BY a.ActionDate DESC, a.AuditID DESC;

        SELECT @RowCount = COUNT(*) FROM @Activity;

        SELECT
            @RowCount AS TotalActivities,
            COUNT(DISTINCT ActorName) AS DistinctActors,
            COUNT(DISTINCT ActionType) AS DistinctActionTypes
        FROM @Activity;

        SELECT * FROM @Activity ORDER BY ActionDate DESC, AuditID DESC;
    END
    ELSE
        THROW 50809, 'Unknown audit report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO
