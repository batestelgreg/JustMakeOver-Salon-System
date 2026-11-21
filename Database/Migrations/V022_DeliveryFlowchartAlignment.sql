/*
   V022 - Delivery flowchart alignment (Figure 10)

   Kini nga migration nag-close sa nahabilin nga gaps kontra sa
   Proposed Delivery Flowchart:

     START (items allocated)
       -> System generates AR (items, qty, date, requestor)
       -> Issue items to the requesting department
       -> Staff checks items against the AR
       -> "Complete and in good condition?"
            NO  -> Staff notes discrepancy on the AR; Inventory notified;
                   item replaced or record corrected
                   -> BALIK sa "Issue items to the requesting department"
            YES -> Staff e-signs the AR
       -> System deducts issued quantity from stock
       -> System marks requisition Fulfilled, archives records,
          notifies requester
       -> END

   Ang gaps nga gi-close dinhi:

     1. "Staff" (ang requesting department) maoy mo-check, mo-note,
        ug mo-e-sign. Kaniadto delivery.manage (Admin/Inventory Staff)
        ra ang makabuhat, ug ang Staff role wala'y delivery.view para
        makaabli sa Delivery page. Karon ang requestor mismo sa AR
        makabuhat sa note + e-sign, ug gihatagan ang Staff role og
        delivery.view. Ang pag-issue sa items (MarkIssued) ug
        re-issue/replacement kay sa inventory side lang gihapon.

     2. Ang "item replaced or record corrected" walay record sa
        system. Karon naay DELIVERIES.CorrectedAt / CorrectedByUserID /
        CorrectionNotes nga gina-set sa bag-ong
        usp_Delivery_RecordCorrection. Ang Reissue mo-require niini,
        mao nga dili na makalaktaw ang loop.

     3. Ang loop mobalik sa "Issue items to the requesting department"
        (Status -> Generated -> MarkIssued pag-usab), dili sa AR
        generation.

   Idempotent: guarded COL_LENGTH / IF NOT EXISTS + CREATE OR ALTER.
   THROW range: 50418 (correction required), 50419 (correction details).
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. COLUMNS - ang "item replaced or record corrected" step
   ============================================================ */
IF COL_LENGTH('dbo.DELIVERIES', 'CorrectedAt') IS NULL
    ALTER TABLE dbo.DELIVERIES ADD CorrectedAt DATETIME NULL;
GO

IF COL_LENGTH('dbo.DELIVERIES', 'CorrectedByUserID') IS NULL
    ALTER TABLE dbo.DELIVERIES ADD CorrectedByUserID INT NULL;
GO

IF COL_LENGTH('dbo.DELIVERIES', 'CorrectionNotes') IS NULL
    ALTER TABLE dbo.DELIVERIES ADD CorrectionNotes NVARCHAR(500) NULL;
GO

/* Kani nga backfill kay para ang mga discrepancy nga na-resolve na
   sa wala pa ang correction tracking dili ma-block sa bag-ong
   Reissue guard (history ra ang lab-as nga data). */
UPDATE dbo.DELIVERIES
SET CorrectedAt = DiscrepancyResolvedAt
WHERE CorrectedAt IS NULL
  AND DiscrepancyResolvedAt IS NOT NULL;
GO

/* ============================================================
   2. ROLE - ang requesting department (Staff) makakita sa AR
   ============================================================ */
IF NOT EXISTS (
    SELECT 1
    FROM ROLE_PERMISSIONS rp
    INNER JOIN ROLES r ON r.RoleID = rp.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE r.RoleName = N'Staff' AND p.PermissionCode = N'delivery.view'
)
    INSERT INTO ROLE_PERMISSIONS (RoleID, PermissionID)
    SELECT r.RoleID, p.PermissionID
    FROM ROLES r
    CROSS JOIN PERMISSIONS p
    WHERE r.RoleName = N'Staff' AND p.PermissionCode = N'delivery.view';
GO

/* ============================================================
   3. NOTE DISCREPANCY - requesting staff o delivery manager
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_NoteDiscrepancy
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga actor gate kay para ang requesting department staff
    -- mismo ang makabuhat sa check ug note (Figure 10: "Staff notes
    -- discrepancy on the AR"). Ang delivery.manage kay fallback.
    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM DELIVERIES d
        INNER JOIN USERS u ON u.UserID = @ActorUserID AND u.IsActive = 1
        WHERE d.DeliveryID = @DeliveryID
          AND d.RequestorUserID = @ActorUserID
    )
        THROW 50401, 'Only the requesting staff or a delivery manager can note a discrepancy on this receipt.', 1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), '') IS NULL
        THROW 50407, 'A discrepancy note is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID AND Status = N'Issued')
        THROW 50408, 'A discrepancy can only be noted on an issued acknowledgement receipt.', 1;

    -- Kani nga update kay nagbutang sa bag-ong note ug nag-reopen
    -- sa discrepancy (ResolvedAt = NULL). Ang correction tracking
    -- i-clear kay kinahanglan bag-ong correction sa bag-ong issue.
    UPDATE DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes)),
        DiscrepancyResolvedAt = NULL,
        CorrectedAt = NULL,
        CorrectedByUserID = NULL,
        CorrectionNotes = NULL
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
   4. RECORD CORRECTION - "item replaced or record corrected"
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_RecordCorrection
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga step kay sa inventory side (sila ang mo-replace o
    -- mo-correct sa record), mao nga delivery.manage ang permission.
    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    )
        THROW 50401, 'You do not have permission to record a delivery correction.', 1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), '') IS NULL
        THROW 50419, 'The correction details are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID AND Status = N'Issued')
        THROW 50408, 'A correction can only be recorded on an issued acknowledgement receipt.', 1;

    -- Kani nga guard kay para naa gyuy note nga gi-correct (ang NO
    -- branch sa Figure 10), dili lang basta correction record.
    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID
                     AND NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL
                     AND DiscrepancyResolvedAt IS NULL)
        THROW 50414, 'Note the discrepancy first before recording a correction.', 1;

    UPDATE DELIVERIES
    SET CorrectedAt = SYSDATETIME(),
        CorrectedByUserID = @ActorUserID,
        CorrectionNotes = LTRIM(RTRIM(@Notes))
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, NULL, 'DELIVERY_CORRECTED',
            CONCAT('Item replacement/record correction recorded on acknowledgement receipt #',
                   @DeliveryID, '.'));
END;
GO

/* ============================================================
   5. RE-ISSUE - balik sa "Issue items to the requesting department"
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

    -- Kani nga guard kay ang "item replaced or record corrected" box:
    -- kinahanglan na-record ang correction sa dili pa mobalik sa
    -- "Issue items to the requesting department".
    IF NOT EXISTS (SELECT 1 FROM DELIVERIES
                   WHERE DeliveryID = @DeliveryID
                     AND CorrectedAt IS NOT NULL)
        THROW 50418, 'Record the item replacement or record correction before re-issuing the acknowledgement receipt.', 1;

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
    -- DiscrepancyNotes ug correction details kay tipigan isip history,
    -- ug ang DiscrepancyResolvedAt kay ang proof nga na-close na.
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
   6. COMPLETE - staff e-sign ug stock deduction
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Complete
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga actor gate kay ang requesting staff mismo ang mo-e-sign
    -- (Figure 10: "Staff e-signs the AR"). delivery.manage kay fallback
    -- para sa Admin/Inventory nga nag-assist sa delivery.
    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM DELIVERIES d
        INNER JOIN USERS u ON u.UserID = @ActorUserID AND u.IsActive = 1
        WHERE d.DeliveryID = @DeliveryID
          AND d.RequestorUserID = @ActorUserID
    )
        THROW 50401, 'Only the requesting staff or a delivery manager can sign and complete this receipt.', 1;

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
   7. GET OVERVIEW - per-row acknowledge + correction state
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

    -- Kani nga flag kay para mahibalo ang UI kung ang actor mismo
    -- ang delivery manager (makakita sa tanang acknowledge actions).
    DECLARE @CanManage BIT = CASE WHEN EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    ) THEN 1 ELSE 0 END;

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

    -- Resultset 2: AR records (newest first). Ordinals 12-13 kay gikan
    -- sa V021; ang mga bag-ong column sa V022 kay 14-17.
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
           d.DiscrepancyResolvedAt,
           CAST(CASE WHEN @CanManage = 1 OR d.RequestorUserID = @ActorUserID
                     THEN 1 ELSE 0 END AS BIT) AS CanAcknowledge,
           d.CorrectedAt,
           d.CorrectionNotes,
           CONCAT(correctedUser.FirstName, ' ', correctedUser.LastName) AS CorrectedByName
    FROM DELIVERIES d
    INNER JOIN USERS reqUser ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN USERS signedUser ON signedUser.UserID = d.SignedByUserID
    LEFT JOIN USERS correctedUser ON correctedUser.UserID = d.CorrectedByUserID
    ORDER BY d.GeneratedDate DESC, d.DeliveryID DESC;
END;
GO
