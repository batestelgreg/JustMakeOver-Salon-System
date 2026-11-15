/* ================================================================
   V006 - SETTINGS MODULE
   ----------------------------------------------------------------
   Kani nga migration kay para sa Settings page (tulo ka bag-ong
   features base sa mga modules nga implemented na):
     1. UNIT_OF_MEASURES - master list sa mga units sa item forms
        (dropdown na instead of free text).
     2. SYSTEM_SETTINGS - key/value preferences, ilabina ang
        DefaultRestockDays (gamiton sa shortage notification sa
        usp_Inventory_IssueStock - hardcoded +7 kani).
     3. Salon branding (SalonName ug SalonTagline) - gamiton sa
        sidebar ug login page.
   Ang tulo kay idempotent. THROW numbers diri: 50360-50370.
   ================================================================ */

USE JustMakeOverSalonDB;
GO

/* ================================================================
   1. UNIT_OF_MEASURES - master list sa mga units.
   ================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'UNIT_OF_MEASURES')
BEGIN
    CREATE TABLE UNIT_OF_MEASURES (
        UomID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UNIT_OF_MEASURES PRIMARY KEY,
        UomName VARCHAR(20) NOT NULL CONSTRAINT UQ_UNIT_OF_MEASURES_Name UNIQUE,
        IsActive BIT NOT NULL CONSTRAINT DF_UNIT_OF_MEASURES_IsActive DEFAULT (1),
        CreatedAt DATETIME2 NOT NULL CONSTRAINT DF_UNIT_OF_MEASURES_CreatedAt DEFAULT (SYSDATETIME())
    );
END;
GO

-- Kani nga seed block kay para sa units nga gigamit sa existing items
-- (lowercase standard; case-insensitive ang comparison sa procs).
SET IDENTITY_INSERT dbo.UNIT_OF_MEASURES ON;
IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = 1)
    INSERT INTO UNIT_OF_MEASURES (UomID, UomName) VALUES (1, 'bottle');
IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = 2)
    INSERT INTO UNIT_OF_MEASURES (UomID, UomName) VALUES (2, 'pair');
IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = 3)
    INSERT INTO UNIT_OF_MEASURES (UomID, UomName) VALUES (3, 'piece');
IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = 4)
    INSERT INTO UNIT_OF_MEASURES (UomID, UomName) VALUES (4, 'tube');
IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = 5)
    INSERT INTO UNIT_OF_MEASURES (UomID, UomName) VALUES (5, 'unit');
SET IDENTITY_INSERT dbo.UNIT_OF_MEASURES OFF;
GO

/* ================================================================
   2. SYSTEM_SETTINGS - key/value preferences.
   ================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'SYSTEM_SETTINGS')
BEGIN
    CREATE TABLE SYSTEM_SETTINGS (
        SettingKey VARCHAR(50) NOT NULL CONSTRAINT PK_SYSTEM_SETTINGS PRIMARY KEY,
        SettingValue NVARCHAR(200) NOT NULL,
        UpdatedAt DATETIME2 NOT NULL CONSTRAINT DF_SYSTEM_SETTINGS_UpdatedAt DEFAULT (SYSDATETIME())
    );
END;
GO

-- Kani nga seed block kay para sa defaults (parehas sa current behavior).
IF NOT EXISTS (SELECT 1 FROM SYSTEM_SETTINGS WHERE SettingKey = 'DefaultRestockDays')
    INSERT INTO SYSTEM_SETTINGS (SettingKey, SettingValue) VALUES ('DefaultRestockDays', '7');
IF NOT EXISTS (SELECT 1 FROM SYSTEM_SETTINGS WHERE SettingKey = 'SalonName')
    INSERT INTO SYSTEM_SETTINGS (SettingKey, SettingValue) VALUES ('SalonName', N'Just MakeOver');
IF NOT EXISTS (SELECT 1 FROM SYSTEM_SETTINGS WHERE SettingKey = 'SalonTagline')
    INSERT INTO SYSTEM_SETTINGS (SettingKey, SettingValue) VALUES ('SalonTagline', N'Beauty Salon & Spa');
GO

/* ================================================================
   3. GET UOMS - master list nga may item count kada unit.
   Gate: settings.manage OR inventory.create OR inventory.update
   (kini nga listahan kay gigamit sad sa inventory item form).
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Settings_GetUoMs
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
          AND p.PermissionCode IN (N'settings.manage', N'inventory.create', N'inventory.update')
    )
        THROW 50360, 'You do not have permission to view the unit of measures.', 1;

    SELECT u.UomID, u.UomName, u.IsActive,
           (SELECT COUNT(*) FROM ITEMS i
            WHERE i.UnitOfMeasure = u.UomName COLLATE DATABASE_DEFAULT) AS ItemCount
    FROM UNIT_OF_MEASURES u
    ORDER BY u.UomName;
END;
GO

/* ================================================================
   4. SAVE UOM - create (UomID NULL) o update (name/status).
   Gate: settings.manage. Dili mo-delete - deactivate lang.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Settings_SaveUom
    @ActorUserID INT,
    @UomID INT = NULL,
    @UomName VARCHAR(20) = NULL,
    @IsActive BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50361, 'You do not have permission to manage the unit of measures.', 1;

    DECLARE @CleanName VARCHAR(20) = NULLIF(LTRIM(RTRIM(@UomName)), '');

    IF @UomID IS NULL
    BEGIN
        -- Kani nga create path: kinahanglan ang name ug dili duplicate.
        IF @CleanName IS NULL
            THROW 50362, 'The unit of measure name is required.', 1;

        IF EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomName = @CleanName)
            THROW 50363, 'This unit of measure already exists.', 1;

        INSERT INTO UNIT_OF_MEASURES (UomName, IsActive) VALUES (@CleanName, 1);
        SELECT SCOPE_IDENTITY() AS UomID;
        RETURN;
    END;

    -- Kani nga update path: existing ra ang target.
    IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = @UomID)
        THROW 50364, 'The unit of measure was not found.', 1;

    IF @CleanName IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM UNIT_OF_MEASURES
                   WHERE UomName = @CleanName AND UomID <> @UomID)
            THROW 50363, 'This unit of measure already exists.', 1;

        UPDATE UNIT_OF_MEASURES SET UomName = @CleanName WHERE UomID = @UomID;
    END;

    IF @IsActive IS NOT NULL
    BEGIN
        -- Kani nga block kay para dili ma-deactivate ang unit nga
        -- gigamit pa sa mga items (mabuwag ang item display).
        IF @IsActive = 0 AND EXISTS (
            SELECT 1 FROM ITEMS
            WHERE UnitOfMeasure = (SELECT UomName FROM UNIT_OF_MEASURES WHERE UomID = @UomID)
              AND IsActive = 1
        )
            THROW 50365, 'This unit of measure is still used by active items and cannot be deactivated.', 1;

        UPDATE UNIT_OF_MEASURES SET IsActive = @IsActive WHERE UomID = @UomID;
    END;
END;
GO

/* ================================================================
   5. GET PREFERENCES - key/value rows (branding + restock days).
   Gate: bisan kinsa nga active user (non-sensitive, gamiton sa
   sidebar branding sa tanang users).
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Settings_GetPreferences
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ActorUserID AND IsActive = 1)
        THROW 50366, 'Your account is inactive or was not found.', 1;

    SELECT SettingKey, SettingValue FROM SYSTEM_SETTINGS ORDER BY SettingKey;
END;
GO

/* ================================================================
   6. SAVE PREFERENCES - upsert sa tulo ka settings keys.
   Gate: settings.manage. Validation: restock days 1-365,
   salon name/tagline dili empty.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Settings_SavePreferences
    @ActorUserID INT,
    @SalonName NVARCHAR(100),
    @SalonTagline NVARCHAR(60),
    @DefaultRestockDays INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50367, 'You do not have permission to manage system settings.', 1;

    IF NULLIF(LTRIM(RTRIM(@SalonName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SalonTagline)), '') IS NULL
        THROW 50368, 'The salon name and tagline are required.', 1;

    IF @DefaultRestockDays IS NULL OR @DefaultRestockDays < 1 OR @DefaultRestockDays > 365
        THROW 50369, 'The default restock days must be between 1 and 365.', 1;

    -- Kani nga upsert block kay para sa tulo ka keys.
    MERGE SYSTEM_SETTINGS AS target
    USING (VALUES
        ('SalonName', @SalonName),
        ('SalonTagline', @SalonTagline),
        ('DefaultRestockDays', CAST(@DefaultRestockDays AS NVARCHAR(10)))
    ) AS source (SettingKey, SettingValue)
    ON target.SettingKey = source.SettingKey
    WHEN MATCHED THEN
        UPDATE SET SettingValue = source.SettingValue, UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (SettingKey, SettingValue) VALUES (source.SettingKey, source.SettingValue);
END;
GO

/* ================================================================
   7. ISSUE STOCK UPDATE - gamiton na ang DefaultRestockDays
      preference sa shortage notification (hardcoded 7 kani).
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_IssueStock
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

    -- Kani nga RepF kay para sa shortage: to Purchasing.
    DECLARE @NewRepFID INT = NULL;
    IF @ShortageQty > 0
    BEGIN
        INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
        VALUES (@ItemID, @ShortageQty, SYSDATETIME(), 'Pending');
        SET @NewRepFID = SCOPE_IDENTITY();
    END;

    IF @RequisitionDetailID IS NOT NULL
    BEGIN
        UPDATE REQUISITION_DETAILS
        SET Status = CASE WHEN @Available > 0 THEN 'Partially Fulfilled' ELSE 'Pending' END
        WHERE RequisitionDetailID = @RequisitionDetailID;
    END;

    -- Kani nga notification kay para sa requester: pending + estimated date.
    -- Kani nga days kay gikan sa DefaultRestockDays preference
    -- (fallback 7 kung wala ang setting).
    DECLARE @RestockDays INT = (
        SELECT TRY_CAST(SettingValue AS INT)
        FROM SYSTEM_SETTINGS
        WHERE SettingKey = 'DefaultRestockDays'
    );
    IF @RestockDays IS NULL OR @RestockDays < 1 OR @RestockDays > 365
        SET @RestockDays = 7;

    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, @RestockDays, CAST(SYSDATETIME() AS DATE)));
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT('Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                   CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME());

    COMMIT TRANSACTION;
    SELECT 'Shortage' AS Outcome, @Available AS ReservedQuantity, @ShortageQty AS ShortageQuantity, @NewRepFID AS RepFID;
END;
GO

/* ================================================================
   8. ITEM CREATE/UPDATE UPDATE - i-validate ang UoM batok sa
      master list (case-insensitive, active lang). Ang existing
      nga items kay dili ma-apil sa validation problem kay ang
      default collation kay case-insensitive.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_CreateItem
    @ActorUserID INT,
    @ItemCode VARCHAR(30) = NULL,
    @ItemName NVARCHAR(200),
    @CategoryID INT,
    @UnitOfMeasure NVARCHAR(40),
    @ReorderPoint INT,
    @UnitPrice DECIMAL(18,2),
    @InitialQuantity INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga block kay para sa auto-generation sa ItemCode kung wala gihatag.
    IF NULLIF(LTRIM(RTRIM(@ItemCode)), '') IS NULL
    BEGIN
        DECLARE @MaxNum INT = (
            SELECT MAX(TRY_CAST(SUBSTRING(ItemCode, 5, 10) AS INT))
            FROM ITEMS
            WHERE ItemCode LIKE 'ITM-[0-9]%'
        );

        DECLARE @Candidate VARCHAR(30) =
            'ITM-' + RIGHT('000' + CAST(ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)), 3);

        WHILE EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @Candidate)
        BEGIN
            SET @MaxNum = ISNULL(@MaxNum, 0) + 1;
            SET @Candidate = 'ITM-' + RIGHT('000' + CAST(@MaxNum AS VARCHAR(10)), 3);
        END;

        SET @ItemCode = @Candidate;
    END;

    IF NULLIF(LTRIM(RTRIM(@ItemName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@UnitOfMeasure)), '') IS NULL
        THROW 50302, 'Item name and unit of measure are required.', 1;

    IF @ReorderPoint < 0 OR @UnitPrice < 0 OR @InitialQuantity < 0
        THROW 50303, 'Reorder point, unit price, and quantity cannot be negative.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.create'
    )
        THROW 50304, 'You do not have permission to create inventory items.', 1;

    IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = @CategoryID)
        THROW 50305, 'The selected category is not valid.', 1;

    -- Kani nga check kay para masiguro nga gikan sa master list ang UoM.
    IF NOT EXISTS (
        SELECT 1 FROM UNIT_OF_MEASURES
        WHERE UomName = @UnitOfMeasure COLLATE DATABASE_DEFAULT AND IsActive = 1
    )
        THROW 50370, 'The unit of measure must be selected from the unit of measures list.', 1;

    IF EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @ItemCode)
        THROW 50306, 'The item code is already used by another item.', 1;

    BEGIN TRANSACTION;

    INSERT INTO ITEMS (ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (@ItemCode, @ItemName, @CategoryID, @UnitOfMeasure, @ReorderPoint, @UnitPrice, 1);

    DECLARE @NewItemID INT = SCOPE_IDENTITY();

    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved)
    VALUES (@NewItemID, @InitialQuantity, 0);

    -- Kani nga log kay para sa initial stock sa bag-ong item.
    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, Remarks, TransactionDate)
    VALUES (@NewItemID, @ActorUserID, 'Stock In', @InitialQuantity, 0, @InitialQuantity, 'INITIAL',
            N'Initial inventory setup.', SYSDATETIME());

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ITEM_CREATED',
            CONCAT('Item ', @ItemCode, ' created with initial stock ', @InitialQuantity, '.'));

    COMMIT TRANSACTION;

    -- Kani nga result kay para makita sa frontend ang generated code.
    SELECT @NewItemID AS ItemID, @ItemCode AS ItemCode;
END;
GO

CREATE OR ALTER PROCEDURE usp_Inventory_UpdateItem
    @ActorUserID INT,
    @ItemID INT,
    @ItemCode VARCHAR(30),
    @ItemName NVARCHAR(200),
    @CategoryID INT,
    @UnitOfMeasure NVARCHAR(40),
    @ReorderPoint INT,
    @UnitPrice DECIMAL(18,2),
    @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ItemCode)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@ItemName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@UnitOfMeasure)), '') IS NULL
        THROW 50307, 'Item code, name, and unit of measure are required.', 1;

    IF @ReorderPoint < 0 OR @UnitPrice < 0
        THROW 50308, 'Reorder point and unit price cannot be negative.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.update'
    )
        THROW 50309, 'You do not have permission to update inventory items.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID)
        THROW 50310, 'The item could not be found.', 1;

    -- Kani nga check kay para masiguro nga gikan sa master list ang UoM.
    IF NOT EXISTS (
        SELECT 1 FROM UNIT_OF_MEASURES
        WHERE UomName = @UnitOfMeasure COLLATE DATABASE_DEFAULT AND IsActive = 1
    )
        THROW 50370, 'The unit of measure must be selected from the unit of measures list.', 1;

    IF EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @ItemCode AND ItemID <> @ItemID)
        THROW 50311, 'The item code is already used by another item.', 1;

    UPDATE ITEMS
    SET ItemCode = @ItemCode, ItemName = @ItemName, CategoryID = @CategoryID,
        UnitOfMeasure = @UnitOfMeasure, ReorderPoint = @ReorderPoint,
        UnitPrice = @UnitPrice, IsActive = @IsActive
    WHERE ItemID = @ItemID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ITEM_UPDATED',
            CONCAT('Item ', @ItemCode, ' details updated.'));
END;
GO
