USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* 
   1. SIGNATURE STAGE LOOKUP
   */

IF OBJECT_ID(N'dbo.DOCUMENT_SIGNATURE_STAGES', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DOCUMENT_SIGNATURE_STAGES
    (
        StageID INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DOCUMENT_SIGNATURE_STAGES PRIMARY KEY,
        DocumentType VARCHAR(40) NOT NULL,
        Stage VARCHAR(40) NOT NULL,
        StageLabel NVARCHAR(80) NOT NULL,
        RoleLabel NVARCHAR(80) NOT NULL,
        PermissionCodes VARCHAR(200) NOT NULL,
        SortOrder INT NOT NULL
            CONSTRAINT DF_DSS_SortOrder DEFAULT (0),
        IsActive BIT NOT NULL
            CONSTRAINT DF_DSS_IsActive DEFAULT (1)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'UQ_DOCUMENT_SIGNATURE_STAGES'
      AND object_id = OBJECT_ID(N'dbo.DOCUMENT_SIGNATURE_STAGES')
)
    CREATE UNIQUE INDEX UQ_DOCUMENT_SIGNATURE_STAGES
        ON dbo.DOCUMENT_SIGNATURE_STAGES (DocumentType, Stage);
GO

/* Kani nga seed kay idempotent: kung naa na ang row, i-update lang
   ang labels/permissions aron parehas ang behavior sa tanan environment. */
MERGE dbo.DOCUMENT_SIGNATURE_STAGES AS target
USING
(
    SELECT * FROM (VALUES
        ('PURCHASE_ORDER', 'Approved', N'Approved by',
         N'Approver', 'requisitions.approve', 10),
        ('RECEIVING_REPORT', 'Received', N'Received by',
         N'Receiver', 'receiving.manage', 10),
        ('RECEIVING_REPORT', 'Checked', N'Checked by',
         N'Checker', 'receiving.manage,purchasing.manage', 20),
        ('DELIVERY_CHECK', 'Checked', N'Checked by',
         N'Checker', 'purchasing.manage', 10),
        ('STOCK_CARD', 'Prepared', N'Prepared by',
         N'Prepared by', 'inventory.update', 10),
        ('STOCK_CARD', 'Custodian', N'Inventory custodian',
         N'Custodian', 'inventory.update', 20),
        ('CORRECTION_REPORT', 'Corrected', N'Corrected by',
         N'Corrected by', 'delivery.manage', 10),
        ('REQUISITION', 'Requested', N'Requested by',
         N'Requestor', 'requisitions.create', 5),
        ('REQUISITION', 'Approved', N'Approved by',
         N'Approver', 'requisitions.approve', 10),
        ('REPLENISHMENT_REQUEST', 'Requested', N'Requested by',
         N'Requestor', 'inventory.update', 10),
        ('REPLENISHMENT_REQUEST', 'Approved', N'Approved by',
         N'Approver', 'purchasing.manage,requisitions.approve', 20),
        ('ACKNOWLEDGEMENT_RECEIPT', 'Issued', N'Issued by',
         N'Inventory Staff', 'delivery.manage', 10),
        ('ACKNOWLEDGEMENT_RECEIPT', 'Received', N'Received by',
         N'Requestor', 'delivery.view', 20)
    ) AS v
    (
        DocumentType, Stage, StageLabel, RoleLabel,
        PermissionCodes, SortOrder
    )
) AS source
ON target.DocumentType = source.DocumentType
   AND target.Stage = source.Stage
WHEN MATCHED THEN
    UPDATE SET
        StageLabel = source.StageLabel,
        RoleLabel = source.RoleLabel,
        PermissionCodes = source.PermissionCodes,
        SortOrder = source.SortOrder,
        IsActive = 1
WHEN NOT MATCHED THEN
    INSERT
    (
        DocumentType, Stage, StageLabel, RoleLabel,
        PermissionCodes, SortOrder, IsActive
    )
    VALUES
    (
        source.DocumentType, source.Stage, source.StageLabel,
        source.RoleLabel, source.PermissionCodes,
        source.SortOrder, 1
    );
GO

/* ============================================================
   2. SIGNATURE STORE
   ============================================================ */

IF OBJECT_ID(N'dbo.DOCUMENT_SIGNATURES', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DOCUMENT_SIGNATURES
    (
        SignatureID BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DOCUMENT_SIGNATURES PRIMARY KEY,
        DocumentType VARCHAR(40) NOT NULL,
        DocumentID INT NOT NULL,
        Stage VARCHAR(40) NOT NULL,
        SignerUserID INT NOT NULL,
        SignerName NVARCHAR(200) NOT NULL,
        SignerRole NVARCHAR(100) NOT NULL,
        SignatureImage NVARCHAR(MAX) NOT NULL,
        DocumentHash CHAR(64) NOT NULL,
        ConfirmationAccepted BIT NOT NULL
            CONSTRAINT DF_DOCUMENT_SIGNATURES_Confirmed DEFAULT (1),
        SignedAt DATETIME2(0) NOT NULL
            CONSTRAINT DF_DOCUMENT_SIGNATURES_SignedAt DEFAULT (SYSDATETIME()),
        IsActive BIT NOT NULL
            CONSTRAINT DF_DOCUMENT_SIGNATURES_IsActive DEFAULT (1),
        RevokedAt DATETIME2(0) NULL,
        RevokedByUserID INT NULL,
        RevokeReason NVARCHAR(500) NULL
    );
END;
GO

IF COL_LENGTH(N'dbo.DOCUMENT_SIGNATURES', N'ConfirmationAccepted') IS NULL
BEGIN
    ALTER TABLE dbo.DOCUMENT_SIGNATURES
        ADD ConfirmationAccepted BIT NOT NULL
            CONSTRAINT DF_DOCUMENT_SIGNATURES_Confirmed DEFAULT (1);
END;
GO

/* Usa ra ka active signature matag document + stage. Ang filtered index
   maoy nag-enforce sa "lock after signing" nga rule. */
IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'UX_DOCUMENT_SIGNATURES_Active'
      AND object_id = OBJECT_ID(N'dbo.DOCUMENT_SIGNATURES')
)
    CREATE UNIQUE INDEX UX_DOCUMENT_SIGNATURES_Active
        ON dbo.DOCUMENT_SIGNATURES (DocumentType, DocumentID, Stage)
        WHERE IsActive = 1;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE name = N'IX_DOCUMENT_SIGNATURES_Document'
      AND object_id = OBJECT_ID(N'dbo.DOCUMENT_SIGNATURES')
)
    CREATE INDEX IX_DOCUMENT_SIGNATURES_Document
        ON dbo.DOCUMENT_SIGNATURES (DocumentType, DocumentID);
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = N'FK_DOCUMENT_SIGNATURES_Signer'
)
    ALTER TABLE dbo.DOCUMENT_SIGNATURES
        ADD CONSTRAINT FK_DOCUMENT_SIGNATURES_Signer
        FOREIGN KEY (SignerUserID) REFERENCES dbo.USERS (UserID);
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = N'FK_DOCUMENT_SIGNATURES_Revoker'
)
    ALTER TABLE dbo.DOCUMENT_SIGNATURES
        ADD CONSTRAINT FK_DOCUMENT_SIGNATURES_Revoker
        FOREIGN KEY (RevokedByUserID) REFERENCES dbo.USERS (UserID);
GO

/* 
   3. DOCUMENT SNAPSHOT HASH
   Kani nga hash kay naka-bind sa immutable business terms sa matag
   document aron ang normal nga status transitions (pananglitan PO
   Approved -> Sent -> Delivered) dili makahimo og false tamper alert,
   pero ang bisan unsang pag-usab sa gidaghanon, presyo, item, o notes
   kay masakpan dayon.
  */

CREATE OR ALTER FUNCTION dbo.fn_DocumentSignatureHash
(
    @DocumentType VARCHAR(40),
    @DocumentID INT
)
RETURNS CHAR(64)
AS
BEGIN
    DECLARE @canonical NVARCHAR(2000);

    IF @DocumentType = 'PURCHASE_ORDER'
    BEGIN
        SELECT @canonical = CONCAT(
            'PO|', po.POID, '|', po.PRID, '|', po.SupplierID, '|',
            po.QuantityOrdered, '|',
            CONVERT(VARCHAR(40), po.UnitPrice, 2), '|',
            CONVERT(VARCHAR(40), po.TotalAmount, 2), '|',
            ISNULL(CONVERT(VARCHAR(30), po.ApprovedByUserID), '')
        )
        FROM dbo.PURCHASE_ORDERS po
        WHERE po.POID = @DocumentID;
    END
    ELSE IF @DocumentType = 'RECEIVING_REPORT'
    BEGIN
        SELECT @canonical = CONCAT(
            'RR|', l.InventoryLogID, '|', l.ItemID, '|',
            l.TransactionType, '|', l.QuantityChange, '|',
            l.PreviousQuantity, '|', l.NewQuantity, '|',
            ISNULL(l.ReferenceType, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), l.ReferenceID), ''), '|',
            CONVERT(VARCHAR(30), l.TransactionDate, 126)
        )
        FROM dbo.INVENTORY_LOGS l
        WHERE l.InventoryLogID = @DocumentID;
    END
    ELSE IF @DocumentType = 'STOCK_CARD'
    BEGIN
        SELECT @canonical = CONCAT(
            'SC|', i.ItemID, '|', i.ItemCode, '|',
            ISNULL(CONVERT(VARCHAR(30), inv.QuantityOnHand), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), inv.QuantityReserved), '0'), '|',
            ISNULL(
                CONVERT(VARCHAR(30),
                    (SELECT MAX(x.InventoryLogID)
                     FROM dbo.INVENTORY_LOGS x
                     WHERE x.ItemID = i.ItemID)),
                '0')
        )
        FROM dbo.ITEMS i
        LEFT JOIN dbo.INVENTORY inv
            ON inv.ItemID = i.ItemID
        WHERE i.ItemID = @DocumentID;
    END
    ELSE IF @DocumentType = 'CORRECTION_REPORT'
    BEGIN
        SELECT @canonical = CONCAT(
            'CR|', d.DeliveryID, '|',
            ISNULL(d.CorrectionNotes, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), d.CorrectedAt, 126), ''), '|',
            ISNULL(CONVERT(VARCHAR(30), d.CorrectedByUserID), '')
        )
        FROM dbo.DELIVERIES d
        WHERE d.DeliveryID = @DocumentID;
    END
    ELSE IF @DocumentType = 'REQUISITION'
    BEGIN
        SELECT @canonical = CONCAT(
            'RF|', r.RequisitionID, '|', r.RequestorUserID, '|',
            CONVERT(VARCHAR(10), r.RequiredDate, 23), '|',
            ISNULL(r.Justification, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), r.DepartmentHeadUserID), '')
        )
        FROM dbo.REQUISITIONS r
        WHERE r.RequisitionID = @DocumentID;
    END
    ELSE IF @DocumentType = 'REPLENISHMENT_REQUEST'
    BEGIN
        SELECT @canonical = CONCAT(
            'REPF|', rr.RepFID, '|', rr.ItemID, '|',
            rr.QuantityNeeded, '|',
            ISNULL(CONVERT(VARCHAR(30), rr.OriginRequisitionID), '')
        )
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.RepFID = @DocumentID;
    END
    ELSE IF @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT'
    BEGIN
        SELECT @canonical = CONCAT(
            'AR|', d.DeliveryID, '|', d.ARCode, '|',
            d.RequisitionID, '|', d.RequestorUserID, '|',
            CONVERT(VARCHAR(30), d.GeneratedDate, 126)
        )
        FROM dbo.DELIVERIES d
        WHERE d.DeliveryID = @DocumentID;
    END
    ELSE IF @DocumentType = 'DELIVERY_CHECK'
    BEGIN
        SELECT @canonical = CONCAT(
            'DR|', dr.DRID, '|', dr.POID, '|',
            CONVERT(VARCHAR(30), dr.DeliveryDate, 126), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityDelivered), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityAccepted), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityRejected), '0')
        )
        FROM dbo.DELIVERY_RECEIPTS dr
        LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS dd
            ON dd.DRID = dr.DRID
        WHERE dr.DRID = @DocumentID;
    END;

    RETURN CONVERT(
        CHAR(64),
        HASHBYTES('SHA2_256', ISNULL(@canonical, N'')),
        2);
END;
GO

/* 
   4. GENERIC SIGN / REVOKE / GET / VERIFY
 */

CREATE OR ALTER PROCEDURE dbo.usp_DocumentSignature_Sign
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT,
    @Stage VARCHAR(40),
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 0,
    /* Kung 0, walay result set. Gigamit sa wrappers aron dili
       mabalda ang ilang kaugalingong response shape. */
    @ReturnResult BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PermissionCodes VARCHAR(200),
        @StageLabel NVARCHAR(80),
        @RoleLabel NVARCHAR(80),
        @SignerName NVARCHAR(200),
        @SignerRole NVARCHAR(100),
        @DocumentHash CHAR(64),
        @EmptyHash CHAR(64),
        @Now DATETIME2(0) = SYSDATETIME(),
        @SignatureID BIGINT,
        @ExistingHash CHAR(64);

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm the signature checkbox before saving.',
            1;

    SELECT
        @PermissionCodes = PermissionCodes,
        @StageLabel = StageLabel,
        @RoleLabel = RoleLabel
    FROM dbo.DOCUMENT_SIGNATURE_STAGES
    WHERE DocumentType = @DocumentType
      AND Stage = @Stage
      AND IsActive = 1;

    IF @PermissionCodes IS NULL
        THROW 50700,
            'The requested signature stage is not configured.',
            1;

    /* Permission check: bisan unsa sa comma-separated codes. */
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
          AND CHARINDEX(
                ',' + p.PermissionCode + ',',
                ',' + @PermissionCodes + ',') > 0
    )
        THROW 50701,
            'You do not have permission to sign this document stage.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50702, 'A signature is required.', 1;

    IF @SignatureImage NOT LIKE N'data:image/%'
        THROW 50703, 'The signature image is not valid.', 1;

    IF LEN(@SignatureImage) > 2000000
        THROW 50704, 'The signature image is too large.', 1;

    SELECT
        @SignerName = LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
        @SignerRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID;

    IF @SignerName IS NULL
        THROW 50705, 'The signer account could not be found.', 1;

    SET @DocumentHash = dbo.fn_DocumentSignatureHash(
        @DocumentType, @DocumentID);
    SET @EmptyHash = CONVERT(
        CHAR(64), HASHBYTES('SHA2_256', N''), 2);

    IF @DocumentHash = @EmptyHash
        THROW 50706,
            'The document could not be found for signing.',
            1;

    /* Record lock check. Para sa STOCK_CARD nga mo-usab ang balanse
       sa dagan sa panahon, kung nausab na ang snapshot hash, i-supersede
       ang daan nga stock card sign-off (preserved sa audit trail).
       Para sa tanang uban nga business documents, locked human mapirmahan. */
    SELECT @ExistingHash = ds.DocumentHash
    FROM dbo.DOCUMENT_SIGNATURES ds
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.Stage = @Stage
      AND ds.IsActive = 1;

    IF @ExistingHash IS NOT NULL
    BEGIN
        IF @DocumentType = 'STOCK_CARD' AND @ExistingHash <> @DocumentHash
        BEGIN
            UPDATE dbo.DOCUMENT_SIGNATURES
            SET IsActive = 0,
                RevokedAt = @Now,
                RevokedByUserID = @ActorUserID,
                RevokeReason = N'Superseded by updated stock card snapshot.'
            WHERE DocumentType = @DocumentType
              AND DocumentID = @DocumentID
              AND Stage = @Stage
              AND IsActive = 1;
        END
        ELSE
        BEGIN
            THROW 50707,
                'This document stage is already signed and locked. Use the correction flow or Admin revoke instead.',
                1;
        END
    END;

    INSERT INTO dbo.DOCUMENT_SIGNATURES
    (
        DocumentType, DocumentID, Stage, SignerUserID, SignerName,
        SignerRole, SignatureImage, DocumentHash, ConfirmationAccepted,
        SignedAt, IsActive
    )
    VALUES
    (
        @DocumentType, @DocumentID, @Stage, @ActorUserID, @SignerName,
        @SignerRole, @SignatureImage, @DocumentHash, 1, @Now, 1
    );

    SET @SignatureID = SCOPE_IDENTITY();

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID, TargetUserID, ActionType, Description
    )
    VALUES
    (
        @ActorUserID,
        @ActorUserID,
        'DOCUMENT_SIGNED',
        CONCAT(
            'Digitally signed ', @DocumentType, ' #', @DocumentID,
            ' (', @Stage, ') as ', @SignerRole,
            ' [hash ', LEFT(@DocumentHash, 12), '].'
        )
    );

    IF @ReturnResult = 1
    BEGIN
        SELECT
            @SignatureID AS SignatureID,
            @DocumentType AS DocumentType,
            @DocumentID AS DocumentID,
            @Stage AS Stage,
            @StageLabel AS StageLabel,
            @RoleLabel AS RoleLabel,
            @SignerName AS SignerName,
            @SignerRole AS SignerRole,
            @DocumentHash AS DocumentHash,
            @Now AS SignedAt,
            CAST(1 AS BIT) AS IsHashValid;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DocumentSignature_Revoke
    @ActorUserID INT,
    @SignatureID BIGINT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @DocType VARCHAR(40),
        @DocID INT,
        @Stage VARCHAR(40),
        @SignerUserID INT;

    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL
        THROW 50710, 'A revoke reason is required.', 1;

    /* Admin ra ang maka-revoke. Ang normal nga correction flow kay
       mo-supersede sa signature, dili mo-delete. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND r.RoleName = N'Admin'
    )
        THROW 50711,
            'Only an Admin can revoke a stored signature.',
            1;

    SELECT
        @DocType = DocumentType,
        @DocID = DocumentID,
        @Stage = Stage,
        @SignerUserID = SignerUserID
    FROM dbo.DOCUMENT_SIGNATURES
    WHERE SignatureID = @SignatureID
      AND IsActive = 1;

    IF @DocType IS NULL
        THROW 50712, 'The active signature was not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = LTRIM(RTRIM(@Reason))
        WHERE SignatureID = @SignatureID
          AND IsActive = 1;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID,
            @SignerUserID,
            'DOCUMENT_SIGNATURE_REVOKED',
            CONCAT(
                'Revoked signature #', @SignatureID,
                ' on ', @DocType, ' #', @DocID,
                ' (', @Stage, '): ', LEFT(LTRIM(RTRIM(@Reason)), 250)
            )
        );

        COMMIT TRANSACTION;

        SELECT N'Signature revoked.' AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DocumentSignature_Get
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS
        WHERE UserID = @ActorUserID
          AND IsActive = 1
    )
        THROW 50720, 'Your session is no longer active.', 1;

    DECLARE @CurrentHash CHAR(64) =
        dbo.fn_DocumentSignatureHash(@DocumentType, @DocumentID);

    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        s.StageLabel,
        s.RoleLabel,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.SignatureImage,
        ds.DocumentHash,
        @CurrentHash AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = @CurrentHash
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.DOCUMENT_SIGNATURES ds
    LEFT JOIN dbo.DOCUMENT_SIGNATURE_STAGES s
        ON s.DocumentType = ds.DocumentType
       AND s.Stage = ds.Stage
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1
    UNION ALL
    /* Para sa Receiving Report nga gikan sa Checked DR, i-apil ang
       Checked-by signature gikan sa Purchasing Delivery Check (by process). */
    SELECT TOP (1)
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        'Checked' AS Stage,
        N'Checked by' AS StageLabel,
        N'Checker' AS RoleLabel,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.SignatureImage,
        ds.DocumentHash,
        dbo.fn_DocumentSignatureHash('DELIVERY_CHECK', ds.DocumentID) AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash('DELIVERY_CHECK', ds.DocumentID)
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.INVENTORY_LOGS l
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON l.ReferenceType = 'REPLENISHMENT'
       AND pr.RepFID = l.ReferenceID
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.PRID = pr.PRID
    INNER JOIN dbo.DELIVERY_RECEIPTS dr
        ON dr.POID = po.POID
    INNER JOIN dbo.DOCUMENT_SIGNATURES ds
        ON ds.DocumentType = 'DELIVERY_CHECK'
       AND ds.DocumentID = dr.DRID
       AND ds.Stage = 'Checked'
       AND ds.IsActive = 1
    WHERE @DocumentType = 'RECEIVING_REPORT'
      AND l.InventoryLogID = @DocumentID
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.DOCUMENT_SIGNATURES existing
          WHERE existing.DocumentType = 'RECEIVING_REPORT'
            AND existing.DocumentID = @DocumentID
            AND existing.Stage = 'Checked'
            AND existing.IsActive = 1
      )
    ORDER BY ds.SignatureID DESC;
END;
GO

/*
   5. BUSINESS ACTION WRAPPERS
 */

/* PO approval + signature. Ang existing usp_Purchasing_ApprovePO
   ang naghimo sa budget/status checks, so usa ra ang engine. */
CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_ApprovePOWithSignature
    @POID INT,
    @ApproverUserID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before approving the purchase order.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50730,
            'A signature is required to approve a purchase order.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Purchasing_ApprovePO
            @POID = @POID,
            @ApproverUserID = @ApproverUserID;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ApproverUserID,
            @DocumentType = 'PURCHASE_ORDER',
            @DocumentID = @POID,
            @Stage = 'Approved',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ApproverUserID,
            @ApproverUserID,
            'PURCHASING_ACTION',
            CONCAT('ApprovePO; PO=', @POID, '; PO approved with digital signature.')
        );

        COMMIT TRANSACTION;

        SELECT @POID AS ID, N'PO approved.' AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* Manual receiving (Receive without reference o RepF receive) + signature.
   Ang usp_Inventory_ReceiveStock ang usa ra ka receiving engine. */
CREATE OR ALTER PROCEDURE dbo.usp_Receiving_ReceiveWithSignature
    @ActorUserID INT,
    @ItemID INT,
    @QuantityReceived INT,
    @RepFID INT = NULL,
    @Remarks NVARCHAR(1000) = NULL,
    @SignatureImage NVARCHAR(MAX) = NULL,
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @InventoryLogID BIGINT;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before recording the receipt.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50731,
            'A signature is required to receive stock.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Inventory_ReceiveStock
            @ActorUserID = @ActorUserID,
            @ItemID = @ItemID,
            @QuantityReceived = @QuantityReceived,
            @RepFID = @RepFID,
            @Remarks = @Remarks;

        /* Kani nga transaction kay nag-insert mismo sa bag-ong log,
           so ang MAX kay ang atong bag-ong row. */
        SELECT @InventoryLogID = MAX(l.InventoryLogID)
        FROM dbo.INVENTORY_LOGS l
        WHERE l.ItemID = @ItemID
          AND l.UserID = @ActorUserID
          AND l.TransactionType = 'Stock In';

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'RECEIVING_REPORT',
            @DocumentID = @InventoryLogID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* Checked supplier delivery receive + signature. */
CREATE OR ALTER PROCEDURE dbo.usp_Receiving_ReceiveCheckedDRWithSignature
    @ActorUserID INT,
    @DRID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RepFID INT,
        @ItemID INT,
        @InventoryLogID BIGINT;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before receiving the checked delivery.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50732,
            'A signature is required to receive a checked delivery.',
            1;

    SELECT
        @RepFID = pr.RepFID,
        @ItemID = dd.ItemID
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.POID = dr.POID
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = po.PRID
    LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS dd
        ON dd.DRID = dr.DRID
    WHERE dr.DRID = @DRID;

    IF @ItemID IS NULL
        THROW 50733, 'The checked delivery could not be found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Purchasing_ReceiveCheckedDR
            @ActorUserID = @ActorUserID,
            @DRID = @DRID;

        SELECT @InventoryLogID = MAX(l.InventoryLogID)
        FROM dbo.INVENTORY_LOGS l
        WHERE l.ItemID = @ItemID
          AND l.UserID = @ActorUserID
          AND l.TransactionType = 'Stock In'
          AND l.ReferenceType = 'REPLENISHMENT'
          AND l.ReferenceID = @RepFID;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'RECEIVING_REPORT',
            @DocumentID = @InventoryLogID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* Correction Report + signature. Kung naay existing active correction
   signature, i-supersede kini (revoked row preserved) kay ang correction
   pwede pa ma-update samtang wala pa na-resolve ang discrepancy. */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_RecordCorrectionWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(500),
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before saving the correction.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50734,
            'A signature is required to record a correction.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_RecordCorrection
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Notes = @Notes;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = N'Superseded by a newer correction record.'
        WHERE DocumentType = 'CORRECTION_REPORT'
          AND DocumentID = @DeliveryID
          AND Stage = 'Corrected'
          AND IsActive = 1;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'CORRECTION_REPORT',
            @DocumentID = @DeliveryID,
            @Stage = 'Corrected',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* Requisition approval + generic signature. Ang existing
   usp_Requisition_Approve kay nag-store pa sa legacy columns para sa
   AR print, ug kining wrapper kay nagdugang sa DOCUMENT_SIGNATURES. */
CREATE OR ALTER PROCEDURE dbo.usp_Requisition_ApproveWithSignature
    @RequisitionID INT,
    @ApproverUserID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before approving the requisition.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50735,
            'A signature is required to approve a requisition.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Requisition_Approve
            @RequisitionID = @RequisitionID,
            @ApproverUserID = @ApproverUserID,
            @Signature = @SignatureImage;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ApproverUserID,
            @DocumentType = 'REQUISITION',
            @DocumentID = @RequisitionID,
            @Stage = 'Approved',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* AR Issue + generic signature store sync. Kung re-issued ang AR,
   i-supersede ang daan nga active Issued signature (audit history kept). */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_MarkIssuedWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before issuing the items.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_MarkIssued
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Signature = @SignatureImage;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = N'Superseded by re-issuance after correction.'
        WHERE DocumentType = 'ACKNOWLEDGEMENT_RECEIPT'
          AND DocumentID = @DeliveryID
          AND Stage = 'Issued'
          AND IsActive = 1;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT',
            @DocumentID = @DeliveryID,
            @Stage = 'Issued',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* AR Complete + generic signature store sync. */
CREATE OR ALTER PROCEDURE dbo.usp_Delivery_CompleteWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before completing the delivery.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_Complete
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Signature = @SignatureImage;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT',
            @DocumentID = @DeliveryID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   6. SIGNATURE AUDIT / VERIFY
 */

CREATE OR ALTER PROCEDURE dbo.usp_DocumentSignature_Verify
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS
        WHERE UserID = @ActorUserID
          AND IsActive = 1
    )
        THROW 50720, 'Your session is no longer active.', 1;

    DECLARE @CurrentHash CHAR(64) =
        dbo.fn_DocumentSignatureHash(@DocumentType, @DocumentID);

    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.DocumentHash,
        @CurrentHash AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = @CurrentHash
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.DOCUMENT_SIGNATURES ds
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1
    ORDER BY ds.SignatureID;
END;
GO
