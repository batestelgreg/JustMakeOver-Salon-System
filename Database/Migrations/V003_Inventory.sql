/* ================================================================
   JustMakeOverSalonDB - Migration V003
   Kani nga migration kay para sa Inventory module: items, stock
   adjustments, issuance (reservation + RepF), receiving (RIM +
   allocation), low-stock alerts ug dashboard panel summary.
   Ang mga procedures kay gigamit sa JustMakeOverSalonApp.Inventory.
   ================================================================ */

USE JustMakeOverSalonDB;
GO

-- Kani nga SET kay gikinahanglan tungod sa computed column sa INVENTORY table.
SET QUOTED_IDENTIFIER ON;
GO

/* ================================================================
   SEED DATA — categories ug sample salon items para sa pagsugod.
   ================================================================ */
SET IDENTITY_INSERT dbo.CATEGORIES ON;
IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = 1)
    INSERT INTO CATEGORIES (CategoryID, CategoryName) VALUES (1, N'Consumables');
IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = 2)
    INSERT INTO CATEGORIES (CategoryID, CategoryName) VALUES (2, N'Hair Care Products');
IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = 3)
    INSERT INTO CATEGORIES (CategoryID, CategoryName) VALUES (3, N'Skin Care Products');
IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = 4)
    INSERT INTO CATEGORIES (CategoryID, CategoryName) VALUES (4, N'Tools & Equipment');
SET IDENTITY_INSERT dbo.CATEGORIES OFF;
GO

-- Kani nga seed block kay para sa sample items nga may initial stock.
SET IDENTITY_INSERT dbo.ITEMS ON;
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-001')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (1, 'ITM-001', N'Shampoo (Salon Size)', 2, N'bottle', 10, 350.00, 1);
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-002')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (2, 'ITM-002', N'Hair Color Cream', 2, N'tube', 15, 180.00, 1);
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-003')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (3, 'ITM-003', N'Disposable Gloves (Pair)', 1, N'pair', 50, 8.00, 1);
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-004')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (4, 'ITM-004', N'Facial Cleanser', 3, N'bottle', 8, 220.00, 1);
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-005')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (5, 'ITM-005', N'Salon Towels', 4, N'piece', 30, 45.00, 1);
IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = 'ITM-006')
    INSERT INTO ITEMS (ItemID, ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (6, 'ITM-006', N'Hair Dryer', 4, N'unit', 3, 1800.00, 1);
SET IDENTITY_INSERT dbo.ITEMS OFF;
GO

-- Kani nga seed block kay para sa inventory balances sa sample items.
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 1)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (1, 24, 0);
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 2)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (2, 9, 0);
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 3)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (3, 120, 0);
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 4)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (4, 12, 0);
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 5)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (5, 18, 0);
IF NOT EXISTS (SELECT 1 FROM INVENTORY WHERE ItemID = 6)
    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved) VALUES (6, 4, 0);
GO

-- Kani nga log seed kay para sa initial stock entries (traceable ang tanan).
IF NOT EXISTS (SELECT 1 FROM INVENTORY_LOGS WHERE ReferenceType = 'INITIAL')
   AND NOT EXISTS (SELECT 1 FROM INVENTORY_LOGS WHERE ReferenceType = 'SEED' AND Remarks = N'Initial inventory setup.')
BEGIN
    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, Remarks, TransactionDate)
    SELECT inv.ItemID,
           (SELECT TOP (1) UserID FROM USERS ORDER BY UserID),
           'Stock In', inv.QuantityOnHand, 0, inv.QuantityOnHand, 'SEED', N'Initial inventory setup.', SYSDATETIME()
    FROM INVENTORY inv
    WHERE NOT EXISTS (
        SELECT 1 FROM INVENTORY_LOGS l WHERE l.ItemID = inv.ItemID AND l.ReferenceType IN ('SEED', 'INITIAL')
    );
END;
GO

/* ================================================================
   DATA FIX — pag-standardize sa legacy log display values.
   Kani nga UPDATE kay display metadata ra (ReferenceType + Remarks);
   dili mohikap ang stock balances, walay delete, walay duplicate.
   Idempotent: ang WHERE conditions dili na mo-match paghuman.
   ================================================================ */
-- Kani nga update kay para sa seed logs: human-readable nga remarks.
UPDATE INVENTORY_LOGS
SET Remarks = N'Initial inventory setup.'
WHERE ReferenceType = 'SEED'
  AND Remarks = N'Initial stock from migration V003.';

-- Kani nga update kay para sa item-creation initial stock: klaro nga tag.
UPDATE INVENTORY_LOGS
SET ReferenceType = 'INITIAL', Remarks = N'Initial inventory setup.'
WHERE ReferenceType = 'MANUAL'
  AND TransactionType = 'Stock In'
  AND Remarks = N'Item created with initial stock.';

-- Kani nga update kay para sa mga adjustment rows: self-referencing ADJ number.
UPDATE INVENTORY_LOGS
SET ReferenceType = 'ADJUSTMENT',
    ReferenceID = InventoryLogID,
    Remarks = ISNULL(NULLIF(LTRIM(RTRIM(Remarks)), ''), N'Inventory quantity manually adjusted.')
WHERE TransactionType = 'Adjustment'
  AND ReferenceType IN ('MANUAL', 'ADJUSTMENT')
  AND (ReferenceID IS NULL OR ReferenceID <> InventoryLogID);

-- Kani nga update kay para sa initial stock rows: self-referencing reference
-- number (ang log row mismo ang tinuod nga initial stock record).
UPDATE INVENTORY_LOGS
SET ReferenceID = InventoryLogID
WHERE ReferenceType IN ('SEED', 'INITIAL')
  AND (ReferenceID IS NULL OR ReferenceID <> InventoryLogID);

-- Kani nga cleanup kay para sa duplicate seed log nga gihimo sa daan nga
-- guard (TransactionType = 'Initial Stock' nga dili jpewan mo-match).
-- Log row ra kini nga duplicate; ang stock balance dili gihikapkan.
DELETE l
FROM INVENTORY_LOGS l
WHERE l.ReferenceType = 'SEED'
  AND EXISTS (
      SELECT 1 FROM INVENTORY_LOGS x
      WHERE x.ItemID = l.ItemID AND x.ReferenceType = 'INITIAL'
  );
GO

-- Kani nga ALTER kay para sa Settings module: toggle-able ang categories.
-- Naka-guard aron idempotent ang migration.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CATEGORIES') AND name = 'IsActive')
BEGIN
    ALTER TABLE dbo.CATEGORIES
        ADD IsActive BIT NOT NULL DEFAULT (1);
END;
GO

/* ================================================================
   1. ITEM LIST — tanang items uban ang live stock balance.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetAll
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
        THROW 50300, 'You do not have permission to view inventory.', 1;

    SELECT i.ItemID, i.ItemCode, i.ItemName, i.CategoryID, c.CategoryName,
           i.UnitOfMeasure, i.ReorderPoint, i.UnitPrice, i.IsActive,
           inv.QuantityOnHand, inv.QuantityReserved,
           (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable,
           CAST(CASE WHEN (inv.QuantityOnHand - inv.QuantityReserved) <= i.ReorderPoint
                THEN 1 ELSE 0 END AS BIT) AS IsLowStock
    FROM ITEMS i
    INNER JOIN CATEGORIES c ON c.CategoryID = i.CategoryID
    INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
    ORDER BY i.IsActive DESC, i.ItemName;
END;
GO

/* ================================================================
   2. CATEGORIES — para sa item form dropdown.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetCategories
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga check kay para makita ra sa settings.manage O inventory.view.
    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.view'
    )
       AND NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50301, 'You do not have permission to view categories.', 1;

    SELECT c.CategoryID, c.CategoryName, c.IsActive,
           (SELECT COUNT(*) FROM ITEMS i WHERE i.CategoryID = c.CategoryID) AS ItemCount
    FROM CATEGORIES c
    ORDER BY c.CategoryName;
END;
GO

/* ================================================================
   2b. NEXT ITEM CODE — auto-generate nga ItemCode para sa form.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetNextItemCode
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
          AND p.PermissionCode = N'inventory.create'
    )
        THROW 50330, 'You do not have permission to create inventory items.', 1;

    -- Kani nga block kay mo-generate sa sunod nga ITM-### code.
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

    SELECT @Candidate AS NextItemCode;
END;
GO

/* ================================================================
   2c. CATEGORY SAVE — para sa Settings module: create o rename
      ug category, ug toggle sa active state.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_SaveCategory
    @ActorUserID INT,
    @CategoryID INT = NULL,
    @CategoryName NVARCHAR(100),
    @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@CategoryName)), '') IS NULL
        THROW 50331, 'The category name is required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50332, 'You do not have permission to manage categories.', 1;

    IF @CategoryID IS NULL
       AND EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryName = LTRIM(RTRIM(@CategoryName)))
        THROW 50333, 'A category with that name already exists.', 1;

    IF @CategoryID IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM CATEGORIES
           WHERE CategoryName = LTRIM(RTRIM(@CategoryName)) AND CategoryID <> @CategoryID)
        THROW 50333, 'A category with that name already exists.', 1;

    IF @CategoryID IS NULL
    BEGIN
        -- Kani nga branch kay para sa pag-himo ug bag-ong category.
        INSERT INTO CATEGORIES (CategoryName, IsActive)
        VALUES (LTRIM(RTRIM(@CategoryName)), @IsActive);

        INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @ActorUserID, 'CATEGORY_CREATED',
                CONCAT('Category "', LTRIM(RTRIM(@CategoryName)), '" created.'));

        SELECT SCOPE_IDENTITY() AS CategoryID;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = @CategoryID)
        THROW 50334, 'The category could not be found.', 1;

    -- Kani nga branch kay para sa rename ug active toggle sa category.
    UPDATE CATEGORIES
    SET CategoryName = LTRIM(RTRIM(@CategoryName)), IsActive = @IsActive
    WHERE CategoryID = @CategoryID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'CATEGORY_UPDATED',
            CONCAT('Category ID ', @CategoryID, ' updated to "',
                   LTRIM(RTRIM(@CategoryName)), '".'));

    SELECT @CategoryID AS CategoryID;
END;
GO

/* ================================================================
   3. ITEM CREATE — bag-ong item ug initial stock.
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

/* ================================================================
   4. ITEM UPDATE — details ug reorder point sa item.
   ================================================================ */
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

/* ================================================================
   5. ADJUST STOCK — manual stock correction nga naka-log.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_AdjustStock
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

    -- Kani nga insert kay para sa adjustment log; ang log row mismo ang
    -- ADJ record, mao nga i-self-reference ang ID.
    DECLARE @AdjustmentLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Adjustment', @QuantityChange, @OnHand, @OnHand + @QuantityChange, 'ADJUSTMENT', 0,
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Inventory quantity manually adjusted.'), SYSDATETIME());

    -- Kani nga update kay para mahimong ADJ-#### ang reference niini.
    SET @AdjustmentLogID = SCOPE_IDENTITY();
    UPDATE INVENTORY_LOGS
    SET ReferenceID = @AdjustmentLogID
    WHERE InventoryLogID = @AdjustmentLogID AND ReferenceID = 0;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ADJUSTED',
            CONCAT('Stock adjusted by ', @QuantityChange, ' for item ID ', @ItemID, '.'));

    COMMIT TRANSACTION;
END;
GO

/* ================================================================
   6. ISSUE STOCK — ang Issuance flow sa flowchart (Figure 8.A).
      START: approved ReF received
      -> check stock availability including reservations
      -> sufficient: reserve requested quantity + update balance
      -> insufficient: reserve available quantity, identify
         shortage, generate RepF, notify requester (pending +
         estimated date) -> END (to Purchasing)
      -> reorder point check: low-stock alert + RepF
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
    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, 7, CAST(SYSDATETIME() AS DATE)));
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
   7. REORDER CHECK — shared helper: low-stock alert + RepF.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_CheckReorderPoint
    @ItemID INT,
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ReorderPoint INT = (SELECT ReorderPoint FROM ITEMS WHERE ItemID = @ItemID);
    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Available INT = @OnHand - @Reserved;

    IF @ReorderPoint IS NULL OR @Available > @ReorderPoint
        RETURN;

    -- Kani nga check kay para walay duplicate RepF samtang open pa ang usaha.
    IF EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE ItemID = @ItemID AND Status = 'Pending')
        RETURN;

    DECLARE @Needed INT = CASE WHEN @Available < 0 THEN @ReorderPoint ELSE (@ReorderPoint - @Available) END;

    IF @Needed <= 0
        RETURN;

    INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
    VALUES (@ItemID, @Needed, SYSDATETIME(), 'Pending');

    -- Kani nga alert kay para sa tanang users nga may inventory.view permission.
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'LOW_STOCK', 'Low stock alert',
           'The stock of an item reached its reorder point. A replenishment request was generated.',
           'ITEM', @ItemID, 0, SYSDATETIME()
    FROM USERS u
    INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';
END;
GO

/* ================================================================
   8. RECEIVE STOCK — ang Receiving flow sa flowchart (Figure 8.B).
      START: items received
      -> record received items (RIM) + increase stock balance
      -> allocate stock to approved requisitions waiting
         + notify requesters -> END (to Delivery)
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_ReceiveStock
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
          AND (p.PermissionCode = N'inventory.update' OR p.PermissionCode = N'receiving.manage')
    )
        THROW 50321, 'You do not have permission to record received stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50322, 'The item is inactive or was not found.', 1;

    IF @RepFID IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE RepFID = @RepFID AND ItemID = @ItemID)
        THROW 50323, 'The replenishment request does not match this item.', 1;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);

    -- Kani nga step kay para ma-record ang RIM ug mo-increase ang balance.
    UPDATE INVENTORY
    SET QuantityOnHand = QuantityOnHand + @QuantityReceived, LastUpdated = SYSDATETIME()
    WHERE ItemID = @ItemID;

    -- Kani nga insert kay para sa receiving log. Kung walá nga RepF,
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

    IF @RepFID IS NOT NULL
    BEGIN
        UPDATE REPLENISHMENT_REQUESTS
        SET Status = 'Processed'
        WHERE RepFID = @RepFID AND Status = 'Pending';
    END;

    -- Kani nga allocation loop kay para sa mga waiting reservations sa item.
    DECLARE @ReservationID INT;
    DECLARE @ReservationDetailID INT;
    DECLARE @ShortageQty INT;
    DECLARE @RequestorUserID INT;

    DECLARE waitingCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.ReservationID, r.RequisitionDetailID,
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
    FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ShortageQty, @RequestorUserID;

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

        -- Kani nga notification kay para sa requester: allocated ug ready for delivery.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_ALLOCATED', 'Stock allocated to your request',
                'Received stock was allocated to your request. It is ready for delivery.',
                'REQUISITION', NULL, 0, SYSDATETIME());

        FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ShortageQty, @RequestorUserID;
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

/* ================================================================
   9. LOGS — recent stock movements para sa audit ug traceability.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetLogs
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
        THROW 50324, 'You do not have permission to view inventory logs.', 1;

    -- Kani nga computed columns kay para sa display: Source ug Reference
    -- format (RF-/RefP-/RR-/ADJ-) base sa tinuod nga transaction records.
    -- Walay fake numbers: SEED/INITIAL walay reference kay wala man silay
    -- baliton nga transaction record, so NULL (mo-display ug — sa frontend).
    SELECT TOP (100) l.InventoryLogID, i.ItemName, i.ItemCode, l.TransactionType,
           l.QuantityChange, l.PreviousQuantity, l.NewQuantity,
           l.ReferenceType, l.ReferenceID, l.Remarks, l.TransactionDate,
           CONCAT(u.FirstName, ' ', u.LastName) AS UserName,
           CASE
               WHEN l.ReferenceType = 'REQUISITION' AND l.ReferenceID IS NOT NULL
                   THEN 'RF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                   THEN 'RefP-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'RECEIVING' AND l.ReferenceID IS NOT NULL
                   THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType IN ('MANUAL', 'ADJUSTMENT') AND l.TransactionType = 'Adjustment'
                   THEN 'ADJ-' + RIGHT('0000' + CAST(ISNULL(l.ReferenceID, l.InventoryLogID) AS VARCHAR(10)), 4)
               WHEN l.ReferenceType IN ('SEED', 'INITIAL') AND l.ReferenceID IS NOT NULL
                   THEN 'ADJ-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               ELSE NULL
           END AS ReferenceDisplay,
           CASE
               WHEN l.ReferenceType IN ('SEED', 'INITIAL') THEN 'Initial Stock'
               WHEN l.TransactionType IN ('Reservation', 'Release', 'Stock Out') THEN 'Issuance'
               WHEN l.TransactionType = 'Stock In' THEN 'Receiving'
               WHEN l.TransactionType = 'Adjustment' THEN 'Adjustment'
               ELSE l.TransactionType
           END AS SourceDisplay
    FROM INVENTORY_LOGS l
    INNER JOIN ITEMS i ON i.ItemID = l.ItemID
    LEFT JOIN USERS u ON u.UserID = l.UserID
    ORDER BY l.TransactionDate DESC, l.InventoryLogID DESC;
END;
GO

/* ================================================================
   10. RESERVATIONS — mga waiting ug reserved nga requests.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetReservations
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
        THROW 50325, 'You do not have permission to view reservations.', 1;

    SELECT r.ReservationID, r.RequisitionDetailID, rd.RequisitionID,
           i.ItemName, i.ItemCode, r.QuantityReserved, r.ReservationDate,
           r.Status,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName
    FROM INVENTORY_RESERVATIONS r
    INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
    INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
    INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
    INNER JOIN USERS reqUser ON reqUser.UserID = req.RequestorUserID
    ORDER BY r.ReservationDate DESC;
END;
GO

/* ================================================================
   11. REPLENISHMENT REQUESTS (RepF) — para sa Purchasing.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetRepFs
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
           f.DateGenerated, f.Status
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    ORDER BY CASE WHEN f.Status = 'Pending' THEN 0 ELSE 1 END, f.DateGenerated DESC;
END;
GO

/* ================================================================
   13. OVERVIEW — usa ra ka call nga magdala sa tanang page data
      (items + categories + reservations + RepFs + logs) aron
      dili na magkagawas ang lima ka database connections matag
      pag-load sa Inventory page.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetOverview
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
        THROW 50329, 'You do not have permission to view inventory.', 1;

    -- Kani nga resultset kay para sa items nga may live stock balance.
    EXEC usp_Inventory_GetAll @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa category dropdown.
    EXEC usp_Inventory_GetCategories @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa active reservations.
    EXEC usp_Inventory_GetReservations @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa replenishment requests.
    EXEC usp_Inventory_GetRepFs @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa recent stock movements.
    EXEC usp_Inventory_GetLogs @ActorUserID = @ActorUserID;
END;
GO

/* ================================================================
   INDEXES — para paspas ang mga linya nga kanunay gipangita sa
   inventory queries (logs, notifications, repfs, reservations).
   ================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_INVENTORY_LOGS_Date')
    CREATE INDEX IX_INVENTORY_LOGS_Date ON dbo.INVENTORY_LOGS (TransactionDate DESC, ItemID);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_NOTIFICATIONS_Recipient')
    CREATE INDEX IX_NOTIFICATIONS_Recipient ON dbo.NOTIFICATIONS (RecipientUserID, IsRead);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_REPF_Item_Status')
    CREATE INDEX IX_REPF_Item_Status ON dbo.REPLENISHMENT_REQUESTS (ItemID, Status);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RESERVATIONS_Detail')
    CREATE INDEX IX_RESERVATIONS_Detail ON dbo.INVENTORY_RESERVATIONS (RequisitionDetailID, Status);
GO

/* ================================================================
   12. PANEL SUMMARY — para sa dashboard inventory panel.
   ================================================================ */
CREATE OR ALTER PROCEDURE usp_Inventory_GetPanel
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
        THROW 50327, 'You do not have permission to view the inventory panel.', 1;

    SELECT
        (SELECT COUNT(*) FROM ITEMS WHERE IsActive = 1) AS TotalItems,

        (SELECT COUNT(*)
         FROM ITEMS i
         INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
         WHERE i.IsActive = 1
           AND (inv.QuantityOnHand - inv.QuantityReserved) <= i.ReorderPoint) AS LowStockItems,

        (SELECT ISNULL(SUM(QuantityReserved), 0) FROM INVENTORY) AS ReservedUnits,

        (SELECT COUNT(*) FROM REPLENISHMENT_REQUESTS WHERE Status = 'Pending') AS PendingRepFs,

        (SELECT COUNT(*)
         FROM INVENTORY_RESERVATIONS r
         INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
         WHERE r.Status = 'Active' AND rd.Status = 'Partially Fulfilled') AS PartialReservations,

        (SELECT COUNT(*) FROM INVENTORY_LOGS
         WHERE TransactionDate >= DATEADD(DAY, -1, SYSDATETIME())) AS RecentMovements;
END;
GO
