/*
    V017_ReplenishmentQuantityRefresh.sql

    Gi-fix ang under-order case sa replenishment:

    Ang usp_Inventory_CheckReorderPoint kay mo-return dayon kung naay
    Pending RepF, so ang QuantityNeeded nga gi-compute sa unang higayon
    dili na ma-update bisan moubos pa ang Available.

    Karon: kung ang Pending RepF wala pa ma-order (walay Purchase Request)
    ug wala pa madawat (QuantityReceived = 0), i-raise ang QuantityNeeded
    ngadto sa kasamtangan nga gap kung mas dako kini.
    Pasaka lang (MAX), dili mopaubos — para dili ma-under-order.

    Kung naa nay PR o partially received ang RepF, dili ni hilabtan ug
    dili usab mag-himo og bag-ong RepF (kay ma-doble ang order).

    Re-runnable (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Inventory_CheckReorderPoint
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

    -- Kini nga quantity kay ang kulang para mobalik sa reorder point.
    DECLARE @Needed INT = CASE WHEN @Available < 0 THEN @ReorderPoint ELSE (@ReorderPoint - @Available) END;

    -- Pending RepF nga wala pay PR ug wala pay nadawat: pwede pa i-adjust
    -- ang quantity kay wala pa may na-order.
    DECLARE @PendingRepFID INT;

    SELECT TOP (1) @PendingRepFID = rr.RepFID
    FROM dbo.REPLENISHMENT_REQUESTS rr
    WHERE rr.ItemID = @ItemID
      AND rr.Status = 'Pending'
      AND rr.QuantityReceived = 0
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID
      )
    ORDER BY rr.RepFID;

    IF @PendingRepFID IS NOT NULL
    BEGIN
        -- Pasaka lang kung mas dako ang kasamtangan nga gap.
        IF @Needed > 0
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET QuantityNeeded = CASE
                    WHEN QuantityNeeded < @Needed THEN @Needed
                    ELSE QuantityNeeded
                END
            WHERE RepFID = @PendingRepFID;

        RETURN;
    END;

    -- Kung naa nay Pending RepF nga naa nay PR o partially received,
    -- ayaw og himo og laing RepF kay ma-doble ang order.
    IF EXISTS (
        SELECT 1 FROM dbo.REPLENISHMENT_REQUESTS
        WHERE ItemID = @ItemID AND Status = 'Pending'
    )
        RETURN;

    IF @Needed <= 0
        RETURN;

    INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
    VALUES (@ItemID, @Needed, SYSDATETIME(), 'Pending');

    -- Kini nga alert kay para sa tanang users nga may inventory.view permission.
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
