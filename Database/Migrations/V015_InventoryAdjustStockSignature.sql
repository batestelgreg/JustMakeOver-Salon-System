/*
    V015_InventoryAdjustStockSignature.sql

    Fixes the runtime error sa Inventory page:

        "Procedure or function 'usp_Inventory_AdjustStock' expects
         parameter '@UserID', which was not supplied."

    Ang hinungdan: ang live database nagpabilin sa daan nga baseline
    nga bersyon sa procedure (@UserID, @Remarks NVARCHAR(500), walay
    permission guard ug walay audit log), samtang ang
    InventoryRepository nag-send og @ActorUserID.

    Kini nga migration kay nag-re-emit sa kasamtangan nga bersyon gikan
    sa V003 (permission check, ADJ self-reference, audit log) para
    mo-match sa C#. Walay data change, ug re-runnable (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Inventory_AdjustStock
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

    -- Kini nga check kay para sa inventory.adjust permission.
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

    -- Diri naka-log ang adjustment; ADJ record ang reference niini.
    DECLARE @AdjustmentLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Adjustment', @QuantityChange, @OnHand, @OnHand + @QuantityChange, 'ADJUSTMENT', 0,
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Inventory quantity manually adjusted.'), SYSDATETIME());

    -- Kini nga update kay para mahimong ADJ-#### ang reference.
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
