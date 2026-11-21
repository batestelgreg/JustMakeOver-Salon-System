/*
   V021 - Delivery discrepancy guard (Figure 10 NO branch)

   Kini nga migration nag-close sa gap sa Delivery flow:

     "Complete and in good condition?" -> NO
       -> staff notes discrepancy, inventory notified,
          item replaced or record corrected,
       -> BALIK sa "Issue items to the requesting department"

   Sa V018, ang Note Discrepancy kay advisory ra: wala niya
   gibag-o ang status, ug ang Complete wala mag-check kung naa
   pay open nga discrepancy. Mao nga makalompos ang AR bisan
   wala pa ma-resolve ang discrepancy (gitago ra ang re-issue
   loop nga optional).

   Karon:
     1. Bag-ong column DELIVERIES.DiscrepancyResolvedAt.
     2. NoteDiscrepancy -> mo-reopen sa discrepancy (ResolvedAt = NULL).
     3. Reissue -> mo-mark sa discrepancy as resolved ug mobalik
        sa 'Generated' para i-issue pag-usab.
     4. Complete -> mo-block kung naay open discrepancy (THROW 50417).
     5. GetOverview -> mo-return sa HasUnresolvedDiscrepancy ug
        DiscrepancyResolvedAt para mahibalo ang UI.

   Kini idempotent: guarded ALTER + CREATE OR ALTER ra.
   THROW range: 50417 (bag-o).
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. COLUMN - kanus-a na-resolve ang discrepancy
   ============================================================ */
IF COL_LENGTH('dbo.DELIVERIES', 'DiscrepancyResolvedAt') IS NULL
    ALTER TABLE dbo.DELIVERIES ADD DiscrepancyResolvedAt DATETIME NULL;
GO

/* Kani nga backfill kay para ang daan nga Completed AR (nga naay
   discrepancy notes) dili ma-flag nga "open" sa UI. Ang marker
   kay ang actuwal nga sign date, o ang issue date kung wala. */
UPDATE dbo.DELIVERIES
SET DiscrepancyResolvedAt = COALESCE(SignedDate, IssuedDate, GeneratedDate)
WHERE Status = N'Completed'
  AND DiscrepancyResolvedAt IS NULL
  AND NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL;
GO

/* ============================================================
   2. NOTE DISCREPANCY - mo-reopen sa discrepancy
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_NoteDiscrepancy
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(1000)
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

    IF NULLIF(LTRIM(RTRIM(@Notes)), '') IS NULL
        THROW 50407, 'A discrepancy note is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID AND Status = N'Issued')
        THROW 50408, 'A discrepancy can only be noted on an issued acknowledgement receipt.', 1;

    -- Kani nga update kay nagbutang sa bag-ong note ug nag-reopen
    -- sa discrepancy (ResolvedAt = NULL) para dili makalompos ang
    -- Complete hangtud ma-reissue.
    UPDATE DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes)),
        DiscrepancyResolvedAt = NULL
    WHERE DeliveryID = @DeliveryID;

    -- Kani nga notification kay para ma-notify ang inventory team
    -- (item replacement / record correction).
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'DELIVERY_DISCREPANCY', 'Delivery discrepancy noted',
           'A discrepancy was noted on an acknowledgement receipt. The item may need replacement or record correction.',
           'DELIVERY', @DeliveryID, 0, SYSDATETIME()
    FROM USERS u
    INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'DELIVERY_DISCREPANCY',
            CONCAT('Discrepancy noted on acknowledgement receipt #', @DeliveryID, '.'));
END;
GO

/* ============================================================
   3. RE-ISSUE - ang NO branch nga mo-balik sa Issue Items
   ============================================================ */
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

    -- Kani nga guard kay para naa gyuy OPEN nga discrepancy nga
    -- gi-correct sa Inventory sa dili pa i-issue pag-usab.
    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID
                     AND NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL
                     AND DiscrepancyResolvedAt IS NULL)
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
    -- DiscrepancyNotes kay tipigan isip history, ug ang
    -- DiscrepancyResolvedAt kay ang proof nga na-close na ang issue.
    UPDATE DELIVERIES
    SET Status = N'Generated',
        IssuedDate = NULL,
        SignedByUserID = NULL,
        SignedDate = NULL,
        DiscrepancyResolvedAt = SYSDATETIME()
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

/* ============================================================
   4. COMPLETE - i-block kung naay open discrepancy
   ============================================================ */
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

    -- Kani nga guard kay ang Figure 10 NO branch: kung naay open
    -- discrepancy, dili pwede mo-deretso sa e-sign. Kinahanglan
    -- i-reissue una (Status -> Generated -> Issued pag-usab).
    IF EXISTS (SELECT 1 FROM DELIVERIES
               WHERE DeliveryID = @DeliveryID
                 AND NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL
                 AND DiscrepancyResolvedAt IS NULL)
        THROW 50417, 'A discrepancy is still open. Re-issue the acknowledgement receipt after the item is replaced or the record is corrected.', 1;

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

/* ============================================================
   5. GET OVERVIEW - ihatag ang open-discrepancy flag sa UI
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetOverview
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
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50400, 'You do not have permission to view deliveries.', 1;

    -- Resultset 1: allocated requisitions (fully reserved na tanang
    -- items ug walay open nga AR pa) — ang START sa Figure 10.
    SELECT r.RequisitionID,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName,
           r.RequestDate,
           r.RequiredDate,
           r.Justification,
           (SELECT STRING_AGG(CONCAT(i.ItemName, N' (Qty: ',
                        CAST(ISNULL(rd.QuantityApproved, rd.QuantityRequested) AS NVARCHAR(20)),
                        N')'), N'; ')
                WITHIN GROUP (ORDER BY rd.RequisitionDetailID)
            FROM REQUISITION_DETAILS rd
            INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
            WHERE rd.RequisitionID = r.RequisitionID) AS ItemsSummary
    FROM REQUISITIONS r
    INNER JOIN USERS reqUser ON reqUser.UserID = r.RequestorUserID
    WHERE r.Status = N'Approved'
      AND EXISTS (SELECT 1 FROM REQUISITION_DETAILS rd
                  WHERE rd.RequisitionID = r.RequisitionID)
      AND NOT EXISTS (SELECT 1 FROM REQUISITION_DETAILS rd
                      WHERE rd.RequisitionID = r.RequisitionID
                        AND rd.Status IN (N'Pending', N'Partially Fulfilled'))
      AND NOT EXISTS (SELECT 1 FROM DELIVERIES d
                      WHERE d.RequisitionID = r.RequisitionID
                        AND d.Status IN (N'Generated', N'Issued'))
    ORDER BY r.RequestDate;

    -- Resultset 2: AR records (newest first). Ang HasSignature kay
    -- index 11, ang duha ka bag-ong column (V021) kay index 12 ug 13.
    SELECT d.DeliveryID,
           d.ARCode,
           d.RequisitionID,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName,
           d.GeneratedDate,
           d.IssuedDate,
           d.SignedDate,
           CONCAT(signedUser.FirstName, ' ', signedUser.LastName) AS SignedByName,
           d.DiscrepancyNotes,
           d.Status,
           (SELECT STRING_AGG(CONCAT(i.ItemName, N' (Qty: ',
                        CAST(di.Quantity AS NVARCHAR(20)), N')'), N'; ')
                WITHIN GROUP (ORDER BY di.DeliveryItemID)
            FROM DELIVERY_ITEMS di
            INNER JOIN ITEMS i ON i.ItemID = di.ItemID
            WHERE di.DeliveryID = d.DeliveryID) AS ItemsSummary,
           CAST(CASE WHEN d.ESignatureData IS NULL THEN 0 ELSE 1 END AS BIT) AS HasSignature,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL
                      AND d.DiscrepancyResolvedAt IS NULL
                     THEN 1 ELSE 0 END AS BIT) AS HasUnresolvedDiscrepancy,
           d.DiscrepancyResolvedAt
    FROM DELIVERIES d
    INNER JOIN USERS reqUser ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN USERS signedUser ON signedUser.UserID = d.SignedByUserID
    ORDER BY d.GeneratedDate DESC, d.DeliveryID DESC;
END;
GO
