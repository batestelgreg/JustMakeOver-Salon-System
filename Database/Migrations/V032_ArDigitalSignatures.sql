/*
    V032_ArDigitalSignatures.sql

    Digital signatures sa Acknowledgement Receipt (AR).

    Kini nga migration kay nag-dugang sa tulo ka signature steps:

    1. APPROVED BY — ang Manager/Department Head mo-sign inig approve sa
       Requisition Form (RF). Ang signature, name, ug approval date/time
       kay ma-store sa REQUISITIONS.
    2. ISSUED BY — ang Inventory Staff mo-sign inig click sa Issue items.
       Ang signature, name, ug issuance date/time kay ma-store sa
       DELIVERIES.
    3. RECEIVED BY — existing na nga Requestor e-sign inig Sign & Complete.

    Importante:
    - Ang signature kay mo-follow sa authenticated actor (walay
      impersonation); ang stored UserID maoy source sa complete name.
    - Ang mga na-issue nga signature kay ma-archive sa
      DELIVERY_SIGNATURE_HISTORY before ma-clear sa re-issue, para
      preserved ang original records.
    - Ang AR print query kay nag-return sa tulo ka signature + dates.

    Idempotent: CREATE OR ALTER / IF NOT EXISTS ra, walay DROP.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. SCHEMA — approval signature sa REQUISITIONS
   ============================================================ */

IF COL_LENGTH('dbo.REQUISITIONS', 'ApprovalSignatureData') IS NULL
    ALTER TABLE dbo.REQUISITIONS
        ADD ApprovalSignatureData NVARCHAR(MAX) NULL;
GO

IF COL_LENGTH('dbo.REQUISITIONS', 'ApprovedDate') IS NULL
    ALTER TABLE dbo.REQUISITIONS
        ADD ApprovedDate DATETIME2 NULL;
GO

/* ============================================================
   2. SCHEMA — issuance signature sa DELIVERIES
   ============================================================ */

IF COL_LENGTH('dbo.DELIVERIES', 'IssuedByUserID') IS NULL
    ALTER TABLE dbo.DELIVERIES
        ADD IssuedByUserID INT NULL;
GO

IF COL_LENGTH('dbo.DELIVERIES', 'IssuedSignatureData') IS NULL
    ALTER TABLE dbo.DELIVERIES
        ADD IssuedSignatureData NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = N'FK_DELIVERIES_Issuer'
      AND parent_object_id = OBJECT_ID(N'dbo.DELIVERIES')
)
    ALTER TABLE dbo.DELIVERIES
        ADD CONSTRAINT FK_DELIVERIES_Issuer
            FOREIGN KEY (IssuedByUserID)
            REFERENCES dbo.USERS (UserID);
GO

/* ============================================================
   3. SIGNATURE HISTORY — preserved bisan ma-re-issue ang AR
   ============================================================ */

IF OBJECT_ID(N'dbo.DELIVERY_SIGNATURE_HISTORY', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DELIVERY_SIGNATURE_HISTORY
    (
        SignatureHistoryID INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DELIVERY_SIGNATURE_HISTORY PRIMARY KEY,
        DeliveryID INT NOT NULL
            CONSTRAINT FK_DSH_Delivery
            REFERENCES dbo.DELIVERIES (DeliveryID),
        Stage VARCHAR(20) NOT NULL
            CONSTRAINT CK_DSH_Stage
            CHECK (Stage IN ('Issued', 'Received')),
        UserID INT NOT NULL
            CONSTRAINT FK_DSH_User
            REFERENCES dbo.USERS (UserID),
        SignatureData NVARCHAR(MAX) NOT NULL,
        SignedAt DATETIME2 NOT NULL
            CONSTRAINT DF_DSH_SignedAt DEFAULT (SYSDATETIME())
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX_DSH_Delivery'
      AND object_id = OBJECT_ID(N'dbo.DELIVERY_SIGNATURE_HISTORY')
)
    CREATE INDEX IX_DSH_Delivery
        ON dbo.DELIVERY_SIGNATURE_HISTORY (DeliveryID, SignatureHistoryID);
GO

/* ============================================================
   4. RF APPROVAL — required na ang Manager signature
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Approve
    @RequisitionID INT,
    @ApproverUserID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RequestorUserID INT;
    DECLARE @ItemID INT;
    DECLARE @QuantityRequested INT;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM USERS u
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND EXISTS
              (
                  SELECT 1
                  FROM ROLE_PERMISSIONS rp
                  INNER JOIN PERMISSIONS p
                      ON p.PermissionID = rp.PermissionID
                  WHERE rp.RoleID = u.RoleID
                    AND p.PermissionCode = 'requisitions.approve'
              )
              AND EXISTS
              (
                  SELECT 1
                  FROM ROLE_PERMISSIONS rp
                  INNER JOIN PERMISSIONS p
                      ON p.PermissionID = rp.PermissionID
                  WHERE rp.RoleID = u.RoleID
                    AND p.PermissionCode = 'inventory.update'
              )
        )
        BEGIN
            THROW 50001, 'You do not have permission to approve requisitions.', 1;
        END;

        IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
            THROW 50004,
                'A signature is required before approving the requisition.',
                1;

        IF @Signature NOT LIKE N'data:image/%'
            THROW 50005,
                'The signature image is not valid.',
                1;

        IF LEN(@Signature) > 2000000
            THROW 50006,
                'The signature image is too large.',
                1;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50002, 'Requisition not found or is no longer pending.', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
        )
        BEGIN
            THROW 50003, 'This requisition has no items.', 1;
        END;

        UPDATE REQUISITIONS
        SET
            Status = 'Approved',
            DepartmentHeadUserID = @ApproverUserID,
            ApprovalSignatureData = @Signature,
            ApprovedDate = SYSDATETIME()
        WHERE RequisitionID = @RequisitionID;

        UPDATE REQUISITION_DETAILS
        SET
            QuantityApproved = QuantityRequested
        WHERE RequisitionID = @RequisitionID;

        DECLARE requisition_items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemID, QuantityRequested
            FROM REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
            ORDER BY RequisitionDetailID;

        OPEN requisition_items;

        FETCH NEXT FROM requisition_items
        INTO @ItemID, @QuantityRequested;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Inventory_IssueStock
                @ActorUserID = @ApproverUserID,
                @ItemID = @ItemID,
                @QuantityRequested = @QuantityRequested,
                @RequisitionID = @RequisitionID;

            FETCH NEXT FROM requisition_items
            INTO @ItemID, @QuantityRequested;
        END;

        CLOSE requisition_items;
        DEALLOCATE requisition_items;

        INSERT INTO USER_AUDIT_LOGS
        (
            ActorUserID,
            TargetUserID,
            ActionType,
            Description
        )
        VALUES
        (
            @ApproverUserID,
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Approved requisition #' + CAST(@RequisitionID AS VARCHAR(20))
        );

        INSERT INTO NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID
        )
        VALUES
        (
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Requisition Approved',
            'Your requisition #' + CAST(@RequisitionID AS VARCHAR(20)) + ' has been approved.',
            'REQUISITION',
            @RequisitionID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'requisition_items') >= 0
            CLOSE requisition_items;

        IF CURSOR_STATUS('local', 'requisition_items') >= -1
            DEALLOCATE requisition_items;

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

/* ============================================================
   5. ISSUE ITEMS — required na ang Inventory Staff signature
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_MarkIssued
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can issue delivery items.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Generated'
    )
        THROW 50406,
            'Only a generated acknowledgement receipt can be marked as issued.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50420,
            'A signature is required before issuing the items.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50421,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50422,
            'The signature image is too large.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.DELIVERIES
    SET Status = N'Issued',
        IssuedByUserID = @ActorUserID,
        IssuedSignatureData = @Signature,
        IssuedDate = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Issued',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        @ActorUserID,
        'DELIVERY_ISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' marked as issued with an inventory signature.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

/* ============================================================
   6. RE-ISSUE — clear current issuance signature, keep history
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Reissue
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can re-issue acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50413,
            'Only an issued acknowledgement receipt can be re-issued.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50414,
            'Note the discrepancy first before re-issuing the acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND CorrectedAt IS NOT NULL
    )
        THROW 50418,
            'Record the item replacement or record correction before re-issuing the acknowledgement receipt.',
            1;

    DECLARE @RequisitionID INT =
    (
        SELECT RequisitionID
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    );

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50415,
            'Correct the requisition allocation before re-issuing the acknowledgement receipt.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.DELIVERIES
    SET Status = N'Generated',
        IssuedDate = NULL,
        IssuedByUserID = NULL,
        IssuedSignatureData = NULL,
        SignedByUserID = NULL,
        SignedDate = NULL,
        DiscrepancyResolvedAt = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        NULL,
        'DELIVERY_REISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' returned to Generated for re-issue after a discrepancy; requisition #',
            @RequisitionID,
            '.'
        )
    );

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'DELIVERY_REISSUED',
        'Acknowledgement receipt re-issued',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' was returned for correction and is ready to be issued again.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1
      AND p.PermissionCode = N'inventory.view';

    COMMIT TRANSACTION;
END;
GO

/* ============================================================
   7. SIGN & COMPLETE — issued signature required first
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_Complete
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanAcknowledge
       (
           @ActorUserID,
           @DeliveryID
       ) = 0
        THROW 50401,
            'Only the Requestor of this receipt or an Admin can acknowledge it.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50409,
            'Only an issued acknowledgement receipt can be signed and completed.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND IssuedByUserID IS NOT NULL
          AND NULLIF
              (
                  LTRIM(RTRIM(IssuedSignatureData)),
                  N''
              ) IS NOT NULL
    )
        THROW 50423,
            'The items must be issued with an inventory signature before the acknowledgement receipt can be completed.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50410,
            'A signature is required before completing the delivery.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50411,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50412,
            'The signature image is too large.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50417,
            'A discrepancy is still open. Re-issue the acknowledgement receipt after the item is replaced or the record is corrected.',
            1;

    DECLARE @RequisitionID INT =
    (
        SELECT RequisitionID
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    );

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50404,
            'All requisition items must be fully allocated before completing the delivery.',
            1;

    BEGIN TRANSACTION;

    DECLARE @ItemID INT;
    DECLARE @DetailID INT;
    DECLARE @Quantity INT;
    DECLARE @OnHand INT;
    DECLARE @Reserved INT;
    DECLARE @ActiveReserved INT;

    DECLARE delivery_items CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            di.ItemID,
            di.RequisitionDetailID,
            di.Quantity
        FROM dbo.DELIVERY_ITEMS di
        WHERE di.DeliveryID = @DeliveryID;

    OPEN delivery_items;

    FETCH NEXT FROM delivery_items
    INTO @ItemID, @DetailID, @Quantity;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @OnHand = QuantityOnHand,
            @Reserved = QuantityReserved
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        IF @OnHand IS NULL
            THROW 50405,
                'No stock record exists for a delivery item.',
                1;

        SET @ActiveReserved = ISNULL
        (
            (
                SELECT SUM(r.QuantityReserved)
                FROM dbo.INVENTORY_RESERVATIONS r
                WHERE r.RequisitionDetailID = @DetailID
                  AND r.Status = N'Active'
            ),
            0
        );

        IF @ActiveReserved < @Quantity
           OR @Reserved < @Quantity
           OR @OnHand < @Quantity
            THROW 50405,
                'The reserved stock for a delivery item is no longer available. Correct the record and try again.',
                1;

        UPDATE dbo.INVENTORY
        SET QuantityOnHand = QuantityOnHand - @Quantity,
            QuantityReserved = QuantityReserved - @Quantity,
            LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        SELECT @OnHand = QuantityOnHand
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS
        (
            ItemID,
            UserID,
            TransactionType,
            QuantityChange,
            PreviousQuantity,
            NewQuantity,
            ReferenceType,
            ReferenceID,
            Remarks,
            TransactionDate
        )
        VALUES
        (
            @ItemID,
            @ActorUserID,
            N'Stock Out',
            -@Quantity,
            @OnHand + @Quantity,
            @OnHand,
            N'DELIVERY',
            @DeliveryID,
            N'Items issued and delivered (acknowledgement receipt).',
            SYSDATETIME()
        );

        UPDATE dbo.INVENTORY_RESERVATIONS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID
          AND Status = N'Active';

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID;

        FETCH NEXT FROM delivery_items
        INTO @ItemID, @DetailID, @Quantity;
    END;

    CLOSE delivery_items;
    DEALLOCATE delivery_items;

    UPDATE dbo.DELIVERIES
    SET Status = N'Completed',
        SignedByUserID = @ActorUserID,
        SignedDate = SYSDATETIME(),
        ESignatureData = @Signature
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Received',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    UPDATE dbo.REQUISITIONS
    SET Status = N'Fulfilled'
    WHERE RequisitionID = @RequisitionID;

    DECLARE @RequestorUserID INT =
    (
        SELECT RequestorUserID
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    );

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    VALUES
    (
        @RequestorUserID,
        'REQUISITION_FULFILLED',
        'Requisition fulfilled',
        'Your requested items have been delivered and your requisition is now fulfilled.',
        'REQUISITION',
        @RequisitionID,
        0,
        SYSDATETIME()
    );

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES
    (
        @ActorUserID,
        @RequestorUserID,
        'DELIVERY_COMPLETED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' signed electronically; requisition #',
            @RequisitionID,
            ' fulfilled.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

/* ============================================================
   8. AR RECEIPT QUERY — tulo ka signature ang ibalik
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetReceipt
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50410,
            'You do not have permission to view acknowledgement receipts.',
            1;

    /* Wala makita ang receipt: walay result set, service ang mo-message. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    )
        RETURN;

    /* Result set 1: receipt header. */
    SELECT
        d.DeliveryID,
        d.ARCode,
        d.RequisitionID,
        CONCAT
        (
            reqUser.FirstName,
            ' ',
            reqUser.LastName
        ) AS RequestorName,
        CASE
            WHEN headUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                headUser.FirstName,
                ' ',
                headUser.LastName
            )
        END AS DepartmentHeadName,
        CONCAT
        (
            genUser.FirstName,
            ' ',
            genUser.LastName
        ) AS GeneratedByName,
        CASE
            WHEN signedUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                signedUser.FirstName,
                ' ',
                signedUser.LastName
            )
        END AS SignedByName,
        CASE
            WHEN correctedUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                correctedUser.FirstName,
                ' ',
                correctedUser.LastName
            )
        END AS CorrectedByName,
        r.RequestDate,
        r.RequiredDate,
        r.Justification,
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        d.Status,
        d.DiscrepancyNotes,
        d.CorrectionNotes,
        d.ESignatureData AS SignatureData,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline,
        CASE
            WHEN issuerUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                issuerUser.FirstName,
                ' ',
                issuerUser.LastName
            )
        END AS IssuedByName,
        d.IssuedSignatureData,
        r.ApprovedDate,
        r.ApprovalSignatureData
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.REQUISITIONS r
        ON r.RequisitionID = d.RequisitionID
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN dbo.USERS headUser
        ON headUser.UserID = r.DepartmentHeadUserID
    INNER JOIN dbo.USERS genUser
        ON genUser.UserID = d.GeneratedByUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    LEFT JOIN dbo.USERS correctedUser
        ON correctedUser.UserID = d.CorrectedByUserID
    LEFT JOIN dbo.USERS issuerUser
        ON issuerUser.UserID = d.IssuedByUserID
    WHERE d.DeliveryID = @DeliveryID;

    /* Result set 2: receipt line items. */
    SELECT
        di.DeliveryItemID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        di.Quantity
    FROM dbo.DELIVERY_ITEMS di
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = di.ItemID
    WHERE di.DeliveryID = @DeliveryID
    ORDER BY di.DeliveryItemID;
END;
GO
