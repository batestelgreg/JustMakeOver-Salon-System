/*
    V018_FlowDeviationFixes.sql

    Kini nga migration kay nag-fix sa lima ka deviation batok sa proposed
    flowcharts:

    1. E-SIGNATURE (Delivery): ang "staff e-signs the AR" kay click ra
       kaniadto. Karon naay DELIVERIES.ESignatureData nga nagtipig sa
       drawn signature (PNG data URL) ug ang usp_Delivery_Complete
       mo-validate nga naay signature sa dili pa mo-deduct sa stock.

    2. RE-ISSUE LOOP (Delivery): kung "Complete and in good condition?"
       = NO ug na-note na ang discrepancy, ang bag-ong
       usp_Delivery_Reissue mo-balik sa AR ngadto sa 'Generated' para
       ma-issue pag-usab human sa correction/replacement.

    3. PO REJECTED -> REQUISITION REQUESTOR (Purchasing): ang trigger
       trg_PurchaseOrders_NotifyRequisitionRequestor mo-notify sa
       requisition requestor (dili lang sa PR creator) kung ma-Rejected
       ang PO, uban sa "Hold or revise the request."

    Re-runnable (IF NOT EXISTS / CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

/* =========================================================
   1. E-signature storage
   ========================================================= */

IF COL_LENGTH('dbo.DELIVERIES', 'ESignatureData') IS NULL
    ALTER TABLE dbo.DELIVERIES ADD ESignatureData NVARCHAR(MAX) NULL;
GO

/* =========================================================
   2. Complete (e-sign) — signature required
   ========================================================= */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Complete
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
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
          AND p.PermissionCode = N'delivery.manage'
    )
        THROW 50401, 'You do not have permission to manage deliveries.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID AND Status = N'Issued')
        THROW 50409, 'Only an issued acknowledgement receipt can be signed and completed.', 1;

    -- Kini nga guard kay para masiguro nga na-capture gyud ang e-sign.
    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50410, 'A signature is required before completing the delivery.', 1;

    -- Kini nga guard kay para data:image/... (PNG/JPEG) ra ang dawaton.
    IF @Signature NOT LIKE N'data:image/%'
        THROW 50411, 'The signature image is not valid.', 1;

    IF LEN(@Signature) > 2000000
        THROW 50412, 'The signature image is too large.', 1;

    DECLARE @RequisitionID INT =
        (SELECT RequisitionID FROM DELIVERIES WHERE DeliveryID = @DeliveryID);

    -- Kani nga guard kay para dili ma-complete ang AR kung naay
    -- item nga wala pa fully allocated (discrepancy nga wala pa
    -- ma-correct).
    IF EXISTS (SELECT 1 FROM REQUISITION_DETAILS
               WHERE RequisitionID = @RequisitionID
                 AND Status IN (N'Pending', N'Partially Fulfilled'))
        THROW 50404, 'All requisition items must be fully allocated before completing the delivery.', 1;

    BEGIN TRANSACTION;

    DECLARE @ItemID INT;
    DECLARE @DetailID INT;
    DECLARE @Quantity INT;
    DECLARE @OnHand INT;
    DECLARE @Reserved INT;
    DECLARE @ActiveReserved INT;

    DECLARE delivery_items CURSOR LOCAL FAST_FORWARD FOR
        SELECT di.ItemID, di.RequisitionDetailID, di.Quantity
        FROM DELIVERY_ITEMS di
        WHERE di.DeliveryID = @DeliveryID;

    OPEN delivery_items;
    FETCH NEXT FROM delivery_items INTO @ItemID, @DetailID, @Quantity;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @OnHand = QuantityOnHand, @Reserved = QuantityReserved
        FROM INVENTORY
        WHERE ItemID = @ItemID;

        IF @OnHand IS NULL
            THROW 50405, 'No stock record exists for a delivery item.', 1;

        SET @ActiveReserved = ISNULL((
            SELECT SUM(r.QuantityReserved)
            FROM INVENTORY_RESERVATIONS r
            WHERE r.RequisitionDetailID = @DetailID AND r.Status = N'Active'
        ), 0);

        -- Kani nga guard kay para masiguro nga buhi pa ang reservation
        -- ug igo ang reserved stock (usa ra ang real nga deduction).
        IF @ActiveReserved < @Quantity OR @Reserved < @Quantity OR @OnHand < @Quantity
            THROW 50405, 'The reserved stock for a delivery item is no longer available. Correct the record and try again.', 1;

        -- Kani nga deduction kay ang usa ra nga Stock Out engine:
        -- on hand ug reserved mo-down pareho (available unaffected).
        UPDATE INVENTORY
        SET QuantityOnHand = QuantityOnHand - @Quantity,
            QuantityReserved = QuantityReserved - @Quantity,
            LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        SELECT @OnHand = QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID;

        -- Kani nga log kay para sa Stock Out movement nga may
        -- AR-#### reference (ang delivery mismo ang record).
        INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, N'Stock Out', -@Quantity,
                @OnHand + @Quantity, @OnHand, N'DELIVERY', @DeliveryID,
                N'Items issued and delivered (acknowledgement receipt).', SYSDATETIME());

        -- Kani nga update kay para ma-fulfill ang mga reservation
        -- nga naserbihan sa delivery ('Fulfilled' ang allowed nga
        -- final status sa CK_RESERVATIONS_Status constraint).
        UPDATE INVENTORY_RESERVATIONS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID AND Status = N'Active';

        -- Kani nga update kay para ma-mark Fulfilled ang detail.
        UPDATE REQUISITION_DETAILS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID;

        FETCH NEXT FROM delivery_items INTO @ItemID, @DetailID, @Quantity;
    END;

    CLOSE delivery_items;
    DEALLOCATE delivery_items;

    -- Kani nga update kay para sa e-sign: ang drawn signature (PNG
    -- data URL) tipigan uban sa signer user ug timestamp.
    UPDATE DELIVERIES
    SET Status = N'Completed',
        SignedByUserID = @ActorUserID,
        SignedDate = SYSDATETIME(),
        ESignatureData = @Signature
    WHERE DeliveryID = @DeliveryID;

    -- Kani nga update kay para ma-mark Fulfilled ang requisition
    -- (archive-ready na, tanang details fulfilled na).
    UPDATE REQUISITIONS
    SET Status = N'Fulfilled'
    WHERE RequisitionID = @RequisitionID;

    DECLARE @RequestorUserID INT =
        (SELECT RequestorUserID FROM DELIVERIES WHERE DeliveryID = @DeliveryID);

    -- Kani nga notification kay para sa requester: fulfilled na.
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'REQUISITION_FULFILLED', 'Requisition fulfilled',
            'Your requested items have been delivered and your requisition is now fulfilled.',
            'REQUISITION', @RequisitionID, 0, SYSDATETIME());

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @RequestorUserID, 'DELIVERY_COMPLETED',
            CONCAT('Acknowledgement receipt #', @DeliveryID,
                   ' signed electronically; requisition #',
                   @RequisitionID, ' fulfilled.'));

    COMMIT TRANSACTION;
END;
GO

/* =========================================================
   3. Re-issue — discrepancy correction loop
   ========================================================= */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Reissue
    @ActorUserID INT,
    @DeliveryID INT
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
          AND p.PermissionCode = N'delivery.manage'
    )
        THROW 50401, 'You do not have permission to manage deliveries.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID AND Status = N'Issued')
        THROW 50413, 'Only an issued acknowledgement receipt can be re-issued.', 1;

    -- Kani nga guard kay para naa gyuy na-note nga discrepancy nga
    -- gi-correct sa Inventory sa dili pa i-issue pag-usab.
    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID
                     AND NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL)
        THROW 50414, 'Note the discrepancy first before re-issuing the acknowledgement receipt.', 1;

    DECLARE @RequisitionID INT =
        (SELECT RequisitionID FROM DELIVERIES WHERE DeliveryID = @DeliveryID);

    -- Kani nga guard kay para masiguro nga na-correct na ang allocation
    -- (parehas sa Complete guard) sa dili pa i-issue pag-usab.
    IF EXISTS (SELECT 1 FROM REQUISITION_DETAILS
               WHERE RequisitionID = @RequisitionID
                 AND Status IN (N'Pending', N'Partially Fulfilled'))
        THROW 50415, 'Correct the requisition allocation before re-issuing the acknowledgement receipt.', 1;

    BEGIN TRANSACTION;

    -- Kani nga update kay nagbalik sa AR ngadto sa 'Generated' para
    -- ma-issue pag-usab human sa replacement/correction. Ang
    -- DiscrepancyNotes kay tipigan isip history sa hitabo.
    UPDATE DELIVERIES
    SET Status = N'Generated',
        IssuedDate = NULL,
        SignedByUserID = NULL,
        SignedDate = NULL
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, NULL, 'DELIVERY_REISSUED',
            CONCAT('Acknowledgement receipt #', @DeliveryID,
                   ' returned to Generated for re-issue after a discrepancy; requisition #',
                   @RequisitionID, '.'));

    -- Kani nga notification kay para sa inventory team (sila ang
    -- nag-correct/replace sa item) nga i-issue pag-usab ang AR.
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'DELIVERY_REISSUED', 'Acknowledgement receipt re-issued',
           CONCAT('Acknowledgement receipt #', @DeliveryID,
                  ' was returned for correction and is ready to be issued again.'),
           'DELIVERY', @DeliveryID, 0, SYSDATETIME()
    FROM USERS u
    INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';

    COMMIT TRANSACTION;
END;
GO

/* =========================================================
   4. PO rejected -> notify the requisition requestor
   ========================================================= */

CREATE OR ALTER TRIGGER dbo.trg_PurchaseOrders_NotifyRequisitionRequestor
ON dbo.PURCHASE_ORDERS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(Status) RETURN;

    ;WITH RejectedPO AS
    (
        SELECT i.POID, i.PRID
        FROM inserted i
        INNER JOIN deleted d ON d.POID = i.POID
        WHERE i.Status = N'Rejected'
          AND ISNULL(d.Status, N'') <> N'Rejected'
    ),
    LinkedPR AS
    (
        SELECT rp.POID, rp.PRID FROM RejectedPO rp
        UNION
        SELECT rp.POID, m.PRID
        FROM RejectedPO rp
        INNER JOIN dbo.PO_PR_Mapping m ON m.POID = rp.POID
    ),
    TargetRequisition AS
    (
        SELECT DISTINCT lp.POID, rr.OriginRequisitionID
        FROM LinkedPR lp
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = lp.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        WHERE rr.OriginRequisitionID IS NOT NULL
    )
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID, NotificationType, Title, Message,
        RelatedEntityType, RelatedEntityID, IsRead, CreatedAt
    )
    SELECT DISTINCT
        rq.RequestorUserID,
        'PO_REJECTED',
        'Purchase order rejected',
        CONCAT('Purchase order #', t.POID,
               ' for your requisition was rejected. Hold or revise the request.'),
        'REQUISITION',
        t.OriginRequisitionID,
        0,
        SYSDATETIME()
    FROM TargetRequisition t
    INNER JOIN dbo.REQUISITIONS rq ON rq.RequisitionID = t.OriginRequisitionID
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.NOTIFICATIONS n
        WHERE n.RecipientUserID = rq.RequestorUserID
          AND n.NotificationType = N'PO_REJECTED'
          AND n.RelatedEntityType = N'REQUISITION'
          AND n.RelatedEntityID = t.OriginRequisitionID
          AND n.Message LIKE CONCAT('Purchase order #', t.POID, ' for your requisition was rejected.%')
    );
END;
GO
