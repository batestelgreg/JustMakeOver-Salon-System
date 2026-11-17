/*
   V010 - Delivery module (Figure 10 Proposed Delivery Flowchart)

   Kani nga migration kay para sa internal delivery sa requesting
   department - ang START kay "items allocated" (approved nga
   requisition nga fully reserved na ang stock), DILI ang POs sa
   suppliers (mao to ang supplier-side delivery, separate nga flow
   nga mokuha sa Purchasing).

   Flow (base sa Figure 10):
     1. System generates Acknowledgement Receipt (AR): items,
        quantity, date, requestor -> DELIVERIES + DELIVERY_ITEMS
        (AR-#### auto code).
     2. Issue items to the requesting department -> Mark as issued.
     3. Staff checks items against the AR.
     4. Discrepancy? NO -> note discrepancy on the AR (inventory
        notified; ang item replacement / record correction kay
        moagi sa existing usp_Inventory_AdjustStock sa Inventory).
     5. YES -> staff e-signs the AR (digital acknowledgement:
        user + timestamp sa AR row).
     6. System deducts issued quantity from stock -> usa ra ang
        deduction engine (diri sa usp_Delivery_Complete), Stock Out
        log nga may AR-#### reference, reservations consumed.
     7. System marks requisition Fulfilled, archives records and
        notifies requester -> REQUISITION_FULFILLED notif.

   Kani nga migration idempotent (guarded CREATE TABLE + CREATE OR
   ALTER procs + triggers). THROW range: 50400-50409.
*/

USE JustMakeOverSalonDB;
GO

/*
   1. TABLES — delivery header (AR) ug ang items niini.
*/
IF OBJECT_ID('dbo.DELIVERIES') IS NULL
BEGIN
    CREATE TABLE dbo.DELIVERIES (
        DeliveryID INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DELIVERIES PRIMARY KEY,
        ARCode VARCHAR(30) NOT NULL
            CONSTRAINT UQ_DELIVERIES_ARCode UNIQUE,
        RequisitionID INT NOT NULL
            CONSTRAINT FK_DELIVERIES_Requisition
            REFERENCES dbo.REQUISITIONS (RequisitionID),
        RequestorUserID INT NOT NULL
            CONSTRAINT FK_DELIVERIES_Requestor
            REFERENCES dbo.USERS (UserID),
        GeneratedByUserID INT NOT NULL
            CONSTRAINT FK_DELIVERIES_Generator
            REFERENCES dbo.USERS (UserID),
        GeneratedDate DATETIME2 NOT NULL
            CONSTRAINT DF_DELIVERIES_Generated DEFAULT (SYSDATETIME()),
        IssuedDate DATETIME2 NULL,
        DiscrepancyNotes NVARCHAR(1000) NULL,
        SignedByUserID INT NULL
            CONSTRAINT FK_DELIVERIES_Signer
            REFERENCES dbo.USERS (UserID),
        SignedDate DATETIME2 NULL,
        Status VARCHAR(30) NOT NULL
            CONSTRAINT CK_DELIVERIES_Status
            CHECK (Status IN (N'Generated', N'Issued', N'Completed'))
    );
END;
GO

IF OBJECT_ID('dbo.DELIVERY_ITEMS') IS NULL
BEGIN
    CREATE TABLE dbo.DELIVERY_ITEMS (
        DeliveryItemID INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DELIVERY_ITEMS PRIMARY KEY,
        DeliveryID INT NOT NULL
            CONSTRAINT FK_DELIVERY_ITEMS_Delivery
            REFERENCES dbo.DELIVERIES (DeliveryID),
        RequisitionDetailID INT NOT NULL
            CONSTRAINT FK_DELIVERY_ITEMS_Detail
            REFERENCES dbo.REQUISITION_DETAILS (RequisitionDetailID),
        ItemID INT NOT NULL
            CONSTRAINT FK_DELIVERY_ITEMS_Item
            REFERENCES dbo.ITEMS (ItemID),
        Quantity INT NOT NULL
            CONSTRAINT CK_DELIVERY_ITEMS_Qty CHECK (Quantity > 0)
    );
END;
GO

/*
   2. GET OVERVIEW — usa ra ka call: (a) allocated requisitions nga
      ready na para sa AR generation, ug (b) ang mga AR records
      (open ug completed). Permission: delivery.view.
*/
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

    -- Resultset 2: AR records (newest first).
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
            WHERE di.DeliveryID = d.DeliveryID) AS ItemsSummary
    FROM DELIVERIES d
    INNER JOIN USERS reqUser ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN USERS signedUser ON signedUser.UserID = d.SignedByUserID
    ORDER BY d.GeneratedDate DESC, d.DeliveryID DESC;
END;
GO

/*
   3. GENERATE AR — system generates the Acknowledgement Receipt
      (items, quantity, date, requestor). Guard: approved nga
      requisition, fully allocated na ang tanang items, ug walay
      open nga AR pa. Permission: delivery.manage.
*/
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GenerateAR
    @ActorUserID INT,
    @RequisitionID INT
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
        THROW 50401, 'You do not have permission to generate acknowledgement receipts.', 1;

    IF NOT EXISTS (SELECT 1 FROM REQUISITIONS
                   WHERE RequisitionID = @RequisitionID AND Status = N'Approved')
        THROW 50402, 'Only an approved requisition can receive an acknowledgement receipt.', 1;

    IF EXISTS (SELECT 1 FROM DELIVERIES
               WHERE RequisitionID = @RequisitionID
                 AND Status IN (N'Generated', N'Issued'))
        THROW 50403, 'This requisition already has an open acknowledgement receipt.', 1;

    -- Kani nga guard kay para masiguro nga fully allocated na ang
    -- tanang items (ang START sa Figure 10 kay "items allocated").
    IF EXISTS (SELECT 1 FROM REQUISITION_DETAILS
               WHERE RequisitionID = @RequisitionID
                 AND Status IN (N'Pending', N'Partially Fulfilled'))
        THROW 50404, 'All requisition items must be fully allocated before generating an acknowledgement receipt.', 1;

    IF NOT EXISTS (SELECT 1 FROM REQUISITION_DETAILS
                   WHERE RequisitionID = @RequisitionID)
        THROW 50405, 'This requisition has no items to deliver.', 1;

    BEGIN TRANSACTION;

    -- Kani nga block kay para sa auto-generation sa AR-#### code.
    DECLARE @MaxNum INT = (
        SELECT MAX(TRY_CAST(SUBSTRING(ARCode, 4, 10) AS INT))
        FROM DELIVERIES
        WHERE ARCode LIKE 'AR-[0-9]%'
    );

    DECLARE @ARCode VARCHAR(30) =
        'AR-' + RIGHT('0000' + CAST(ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM DELIVERIES WHERE ARCode = @ARCode)
    BEGIN
        SET @MaxNum = ISNULL(@MaxNum, 0) + 1;
        SET @ARCode = 'AR-' + RIGHT('0000' + CAST(@MaxNum AS VARCHAR(10)), 4);
    END;

    DECLARE @RequestorUserID INT =
        (SELECT RequestorUserID FROM REQUISITIONS WHERE RequisitionID = @RequisitionID);

    INSERT INTO DELIVERIES (ARCode, RequisitionID, RequestorUserID, GeneratedByUserID, GeneratedDate, Status)
    VALUES (@ARCode, @RequisitionID, @RequestorUserID, @ActorUserID, SYSDATETIME(), N'Generated');

    DECLARE @DeliveryID INT = SCOPE_IDENTITY();

    -- Kani nga items snapshot kay gikan sa requisition details
    -- (usa ra ang reference: RequisitionDetailID nga reserved na).
    INSERT INTO DELIVERY_ITEMS (DeliveryID, RequisitionDetailID, ItemID, Quantity)
    SELECT @DeliveryID, rd.RequisitionDetailID, rd.ItemID,
           ISNULL(rd.QuantityApproved, rd.QuantityRequested)
    FROM REQUISITION_DETAILS rd
    WHERE rd.RequisitionID = @RequisitionID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @RequestorUserID, 'DELIVERY_AR_GENERATED',
            CONCAT('Acknowledgement receipt ', @ARCode, ' generated for requisition #',
                   @RequisitionID, '.'));

    COMMIT TRANSACTION;

    SELECT @DeliveryID AS DeliveryID, @ARCode AS ARCode;
END;
GO

/*
   4. MARK ISSUED — issue items to the requesting department
      (manual step sa Figure 10, gi-record lang). Permission:
      delivery.manage.
*/
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_MarkIssued
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
                   WHERE DeliveryID = @DeliveryID AND Status = N'Generated')
        THROW 50406, 'Only a generated acknowledgement receipt can be marked as issued.', 1;

    UPDATE DELIVERIES
    SET Status = N'Issued', IssuedDate = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'DELIVERY_ISSUED',
            CONCAT('Acknowledgement receipt #', @DeliveryID, ' marked as issued.'));
END;
GO

/*
   5. NOTE DISCREPANCY — "Staff notes discrepancy on the AR;
      inventory notified; item replaced or record corrected"
      (NO branch sa diamond). Ang AR kay pabilin Issued para
      ma-re-check maong mo-loop back sa issue step. Ang record
      correction kay moagi sa usp_Inventory_AdjustStock. Permission:
      delivery.manage.
*/
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

    UPDATE DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes))
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

/*
   6. COMPLETE (E-SIGN) — "Staff e-signs the AR" YES branch:
      digital acknowledgement (user + timestamp), deduct issued
      quantity from stock (USA RA ang deduction engine: Stock Out
      log + AR-#### reference + reservations consumed), mark
      requisition Fulfilled, ug notify requester. Permission:
      delivery.manage.
*/
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Complete
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
        THROW 50409, 'Only an issued acknowledgement receipt can be signed and completed.', 1;

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

    -- Kani nga update kay para sa e-sign (digital acknowledgement):
    -- signer user + timestamp sa AR row, ug Completed nga status.
    UPDATE DELIVERIES
    SET Status = N'Completed', SignedByUserID = @ActorUserID, SignedDate = SYSDATETIME()
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
            CONCAT('Acknowledgement receipt #', @DeliveryID, ' signed; requisition #',
                   @RequisitionID, ' fulfilled.'));

    COMMIT TRANSACTION;
END;
GO

/*
   7. LOG DISPLAY — i-reuse ang usp_Inventory_GetLogs nga may
      dugang nga AR-#### branch para sa delivery movements
      (display metadata ra, walay baliton nga transaction).
*/
CREATE OR ALTER PROCEDURE dbo.usp_Inventory_GetLogs
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

    SELECT TOP (100) l.InventoryLogID, i.ItemName, i.ItemCode, l.TransactionType,
           l.QuantityChange, l.PreviousQuantity, l.NewQuantity,
           l.ReferenceType, l.ReferenceID, l.Remarks, l.TransactionDate,
           CONCAT(u.FirstName, ' ', u.LastName) AS UserName,
           CASE
               WHEN l.ReferenceType = 'REQUISITION' AND l.ReferenceID IS NOT NULL
                   THEN 'RF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'DELIVERY' AND l.ReferenceID IS NOT NULL
                   THEN 'AR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
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

/*
   8. AUTO-MARK TRIGGERS — ang "action accomplished" principle
      (parehas sa V009):
      a) Ang DELIVERY_DISCREPANCY notifs kay mo-auto-mark read
         kung ma-complete na ang AR (na-correct na ang record).
      b) Ang requestor FYI notifs (REQUISITION_APPROVED,
         STOCK_RESERVED) kay mo-auto-mark read kung ma-Fulfilled
         na ang requisition - ang delivery mao ang ilang
         "completing action" nga gibilin sa V009.
*/
CREATE OR ALTER TRIGGER dbo.trg_DELIVERIES_AutoMarkNotifications
ON dbo.DELIVERIES
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.DeliveryID = i.DeliveryID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_DISCREPANCY'
      AND n.RelatedEntityType = N'DELIVERY'
      AND i.Status = N'Completed'
      AND n.IsRead = 0;
END;
GO

CREATE OR ALTER TRIGGER dbo.trg_REQUISITIONS_FulfilledAutoMarkNotifications
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType IN (N'REQUISITION_APPROVED', N'STOCK_RESERVED')
      AND n.RelatedEntityType = N'REQUISITION'
      AND i.Status = N'Fulfilled'
      AND n.IsRead = 0;
END;
GO

/*
   9. INDEXES — para paspas ang mga delivery queries.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DELIVERIES_Requisition_Status')
    CREATE INDEX IX_DELIVERIES_Requisition_Status
        ON dbo.DELIVERIES (RequisitionID, Status);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DELIVERY_ITEMS_Delivery')
    CREATE INDEX IX_DELIVERY_ITEMS_Delivery
        ON dbo.DELIVERY_ITEMS (DeliveryID);
GO
