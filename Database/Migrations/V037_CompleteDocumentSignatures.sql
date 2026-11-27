USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

MERGE dbo.DOCUMENT_SIGNATURE_STAGES AS target
USING
(
    SELECT * FROM (VALUES
        ('PURCHASE_ORDER', 'Requested', N'Requested by',
         N'Purchasing Staff', 'purchasing.manage', 5),
        ('REPLENISHMENT_REQUEST', 'Inventory', N'Inventory staff',
         N'Inventory Staff', 'inventory.update,receiving.manage', 15),
        ('STOCK_CARD', 'Prepared', N'Prepared by',
         N'Prepared by', 'inventory.create,inventory.update', 10),
        ('STOCK_CARD', 'Custodian', N'Inventory custodian',
         N'Custodian', 'inventory.update,inventory.adjust,receiving.manage', 20)
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

/* 
   1. CORRECTION REPORT — include Requestor & Issued By signatures
 */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetCorrectionReport
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
          AND p.PermissionCode IN ('delivery.view', 'delivery.manage')
    )
        THROW 50606,
            'You do not have permission to print correction reports.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    )
        RETURN;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
       AND NOT EXISTS
       (
           SELECT 1
           FROM dbo.DELIVERIES
           WHERE DeliveryID = @DeliveryID
             AND RequestorUserID = @ActorUserID
       )
        THROW 50607,
            'You can only view correction reports for your own acknowledgement receipts.',
            1;

    /* Result set 1 correction report header + AR digital signatures. */
    SELECT
        d.DeliveryID,
        d.ARCode,
        d.RequisitionID,
        LTRIM(RTRIM(CONCAT(
            requestor.FirstName, ' ', requestor.LastName
        ))) AS RequestorName,
        CASE
            WHEN head.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                head.FirstName, ' ', head.LastName
            )))
        END AS DepartmentHeadName,
        CASE
            WHEN issuer.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                issuer.FirstName, ' ', issuer.LastName
            )))
        END AS IssuedByName,
        LTRIM(RTRIM(CONCAT(
            generatedBy.FirstName, ' ', generatedBy.LastName
        ))) AS GeneratedByName,
        CASE
            WHEN correctedBy.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                correctedBy.FirstName, ' ', correctedBy.LastName
            )))
        END AS CorrectedByName,
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        d.Status,
        d.DiscrepancyNotes,
        d.DiscrepancyResolvedAt,
        d.CorrectionNotes,
        d.CorrectedAt,
        r.Justification,
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
            WHEN signedUser.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                signedUser.FirstName, ' ', signedUser.LastName
            )))
        END AS SignedByName,
        d.ESignatureData AS RequestorSignatureData,
        d.IssuedSignatureData
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.REQUISITIONS r
        ON r.RequisitionID = d.RequisitionID
    INNER JOIN dbo.USERS requestor
        ON requestor.UserID = d.RequestorUserID
    INNER JOIN dbo.USERS generatedBy
        ON generatedBy.UserID = d.GeneratedByUserID
    LEFT JOIN dbo.USERS head
        ON head.UserID = r.DepartmentHeadUserID
    LEFT JOIN dbo.USERS issuer
        ON issuer.UserID = d.IssuedByUserID
    LEFT JOIN dbo.USERS correctedBy
        ON correctedBy.UserID = d.CorrectedByUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    WHERE d.DeliveryID = @DeliveryID;

    /* Result set 2 AR line items. */
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

    /* Result set 3 preserved signature history (audit trail). */
    SELECT
        h.Stage,
        h.SignedAt,
        LTRIM(RTRIM(CONCAT(
            u.FirstName, ' ', u.LastName
        ))) AS UserName
    FROM dbo.DELIVERY_SIGNATURE_HISTORY h
    INNER JOIN dbo.USERS u
        ON u.UserID = h.UserID
    WHERE h.DeliveryID = @DeliveryID
    ORDER BY h.SignatureHistoryID;
END;
GO

/* 
   2. REQUISITION FORM PRINT — include Received By from completed AR
 */

CREATE OR ALTER PROCEDURE dbo.usp_Requisition_GetPrint
    @ActorUserID INT,
    @RequisitionID INT
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
          AND p.PermissionCode IN
          (
              'requisitions.view',
              'requisitions.create',
              'requisitions.approve'
          )
    )
        THROW 50602,
            'You do not have permission to print requisition forms.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
    )
        RETURN;

    /* Result set 1 requisition header + completed delivery receipt sign-off. */
    SELECT
        r.RequisitionID,
        LTRIM(RTRIM(CONCAT(
            requestor.FirstName, ' ', requestor.LastName
        ))) AS RequestorName,
        requestor.Email AS RequestorEmail,
        CASE
            WHEN head.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                head.FirstName, ' ', head.LastName
            )))
        END AS DepartmentHeadName,
        r.RequestDate,
        r.RequiredDate,
        r.Status,
        r.Justification,
        r.RejectionReason,
        r.ApprovedDate,
        r.ApprovalSignatureData,
        r.ArchivedAt,
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
        del.ReceivedByName,
        del.ReceivedDate,
        del.ReceivedSignatureData
    FROM dbo.REQUISITIONS r
    INNER JOIN dbo.USERS requestor
        ON requestor.UserID = r.RequestorUserID
    LEFT JOIN dbo.USERS head
        ON head.UserID = r.DepartmentHeadUserID
    OUTER APPLY
    (
        SELECT TOP (1)
            LTRIM(RTRIM(CONCAT(su.FirstName, ' ', su.LastName))) AS ReceivedByName,
            d.SignedDate AS ReceivedDate,
            d.ESignatureData AS ReceivedSignatureData
        FROM dbo.DELIVERIES d
        LEFT JOIN dbo.USERS su
            ON su.UserID = ISNULL(d.SignedByUserID, d.RequestorUserID)
        WHERE d.RequisitionID = r.RequisitionID
          AND d.Status = N'Completed'
        ORDER BY d.SignedDate DESC, d.DeliveryID DESC
    ) del
    WHERE r.RequisitionID = @RequisitionID;

    /* Result set 2 requisition line items. */
    SELECT
        rd.RequisitionDetailID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        rd.QuantityRequested,
        rd.QuantityApproved,
        rd.Status AS DetailStatus
    FROM dbo.REQUISITION_DETAILS rd
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rd.ItemID
    WHERE rd.RequisitionID = @RequisitionID
    ORDER BY rd.RequisitionDetailID;
END;
GO

/* 
   3. RECEIVING WRAPPERS — auto-stamp STOCK_CARD Custodian &
      REPLENISHMENT_REQUEST Inventory when receiving stock
 */

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

        /* Auto-stamp Stock Card Custodian with latest receiving sign-off. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.DOCUMENT_SIGNATURES
            WHERE DocumentType = 'STOCK_CARD'
              AND DocumentID = @ItemID
              AND Stage = 'Custodian'
              AND IsActive = 1
              AND DocumentHash = dbo.fn_DocumentSignatureHash('STOCK_CARD', @ItemID)
        )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'STOCK_CARD',
                @DocumentID = @ItemID,
                @Stage = 'Custodian',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        /* Auto-stamp RepF Inventory Staff stage if not yet signed. */
        IF @RepFID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'REPLENISHMENT_REQUEST'
                 AND DocumentID = @RepFID
                 AND Stage = 'Inventory'
                 AND IsActive = 1
           )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'REPLENISHMENT_REQUEST',
                @DocumentID = @RepFID,
                @Stage = 'Inventory',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

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
        @InventoryLogID BIGINT,
        @CheckerUserID INT,
        @CheckerName NVARCHAR(200),
        @CheckerRole NVARCHAR(100),
        @CheckerSig NVARCHAR(MAX),
        @CheckedAt DATETIME2(0),
        @RRHash CHAR(64);

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

        /* Copy Purchasing checker's signature from DELIVERY_CHECK to RECEIVING_REPORT Checked. */
        SELECT TOP (1)
            @CheckerUserID = ds.SignerUserID,
            @CheckerName = ds.SignerName,
            @CheckerRole = ds.SignerRole,
            @CheckerSig = ds.SignatureImage,
            @CheckedAt = ds.SignedAt
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE ds.DocumentType = 'DELIVERY_CHECK'
          AND ds.DocumentID = @DRID
          AND ds.Stage = 'Checked'
          AND ds.IsActive = 1
        ORDER BY ds.SignatureID DESC;

        IF @CheckerUserID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'RECEIVING_REPORT'
                 AND DocumentID = @InventoryLogID
                 AND Stage = 'Checked'
                 AND IsActive = 1
           )
        BEGIN
            SET @RRHash = dbo.fn_DocumentSignatureHash('RECEIVING_REPORT', @InventoryLogID);

            INSERT INTO dbo.DOCUMENT_SIGNATURES
            (
                DocumentType, DocumentID, Stage, SignerUserID, SignerName,
                SignerRole, SignatureImage, DocumentHash, ConfirmationAccepted,
                SignedAt, IsActive
            )
            VALUES
            (
                'RECEIVING_REPORT', @InventoryLogID, 'Checked',
                @CheckerUserID, @CheckerName, @CheckerRole, @CheckerSig,
                @RRHash, 1, @CheckedAt, 1
            );
        END;

        /* Auto-stamp Stock Card Custodian with latest receiving sign-off. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.DOCUMENT_SIGNATURES
            WHERE DocumentType = 'STOCK_CARD'
              AND DocumentID = @ItemID
              AND Stage = 'Custodian'
              AND IsActive = 1
              AND DocumentHash = dbo.fn_DocumentSignatureHash('STOCK_CARD', @ItemID)
        )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'STOCK_CARD',
                @DocumentID = @ItemID,
                @Stage = 'Custodian',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        /* Auto-stamp RepF Inventory Staff stage if not yet signed. */
        IF @RepFID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'REPLENISHMENT_REQUEST'
                 AND DocumentID = @RepFID
                 AND Stage = 'Inventory'
                 AND IsActive = 1
           )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'REPLENISHMENT_REQUEST',
                @DocumentID = @RepFID,
                @Stage = 'Inventory',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

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
   4. UNIFIED PRINT SIGNATURE PACK (DIRECT + LINKED FALLBACKS)
 */

CREATE OR ALTER PROCEDURE dbo.usp_DocumentSignature_GetPrintPack
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
        WHERE UserID = @ActorUserID AND IsActive = 1
    )
        THROW 50711, 'Your session is no longer active.', 1;

    DECLARE @Result TABLE
    (
        SignatureID BIGINT NULL,
        DocumentType VARCHAR(40) NOT NULL,
        DocumentID INT NOT NULL,
        Stage VARCHAR(40) NOT NULL,
        StageLabel NVARCHAR(80) NULL,
        SignerUserID INT NULL,
        SignerName NVARCHAR(200) NULL,
        SignerRole NVARCHAR(100) NULL,
        SignatureImage NVARCHAR(MAX) NULL,
        DocumentHash CHAR(64) NULL,
        SignedAt DATETIME2(0) NULL,
        IsHashValid BIT NOT NULL DEFAULT (1),
        SortOrder INT NOT NULL DEFAULT (0)
    );

    /* Direct active signatures on the document itself. */
    INSERT INTO @Result
    (
        SignatureID, DocumentType, DocumentID, Stage, StageLabel,
        SignerUserID, SignerName, SignerRole, SignatureImage,
        DocumentHash, SignedAt, IsHashValid, SortOrder
    )
    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        ISNULL(st.StageLabel, ds.Stage),
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignatureImage,
        ds.DocumentHash,
        ds.SignedAt,
        CAST(CASE
            WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID)
                THEN 1 ELSE 0
        END AS BIT),
        ISNULL(st.SortOrder, 50)
    FROM dbo.DOCUMENT_SIGNATURES ds
    LEFT JOIN dbo.DOCUMENT_SIGNATURE_STAGES st
        ON st.DocumentType = ds.DocumentType
       AND st.Stage = ds.Stage
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1;

    /*  PURCHASE_ORDER: fallback Requested from linked RepF Approved (Create PR) */
    IF @DocumentType = 'PURCHASE_ORDER'
       AND NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Requested')
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'PURCHASE_ORDER',
            @DocumentID,
            'Requested',
            N'Requested by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            5
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr
            ON pr.PRID = po.PRID
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'REPLENISHMENT_REQUEST'
           AND ds.DocumentID = pr.RepFID
           AND ds.Stage = 'Approved'
           AND ds.IsActive = 1
        WHERE po.POID = @DocumentID
        ORDER BY ds.SignatureID DESC;
    END;

    /*  RETURN_SLIP (@DocumentID = DRID): Recorded (DR Checked or RepF Approved) + Approved (PO Approved)  */
    IF @DocumentType = 'RETURN_SLIP'
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'RETURN_SLIP',
            @DocumentID,
            'Recorded',
            N'Recorded by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            10
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE ds.DocumentType = 'DELIVERY_CHECK'
          AND ds.DocumentID = @DocumentID
          AND ds.Stage = 'Checked'
          AND ds.IsActive = 1
        ORDER BY ds.SignatureID DESC;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Recorded')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RETURN_SLIP',
                @DocumentID,
                'Recorded',
                N'Recorded by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                10
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
            INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'REPLENISHMENT_REQUEST'
               AND ds.DocumentID = pr.RepFID
               AND ds.Stage = 'Approved'
               AND ds.IsActive = 1
            WHERE dr.DRID = @DocumentID
            ORDER BY ds.SignatureID DESC;
        END;

        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'RETURN_SLIP',
            @DocumentID,
            'Approved',
            N'Approved by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            30
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'PURCHASE_ORDER'
           AND ds.DocumentID = dr.POID
           AND ds.Stage = 'Approved'
           AND ds.IsActive = 1
        WHERE dr.DRID = @DocumentID
        ORDER BY ds.SignatureID DESC;
    END;

    /*  RECEIVING_REPORT (@DocumentID = InventoryLogID):
           Checked  -> fallback from linked DELIVERY_CHECK Checked (Purchasing Staff)
           Approved -> fallback from linked PURCHASE_ORDER Approved (Manager)  */
    IF @DocumentType = 'RECEIVING_REPORT'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Checked')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RECEIVING_REPORT',
                @DocumentID,
                'Checked',
                N'Checked by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                20
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
            WHERE l.InventoryLogID = @DocumentID
            ORDER BY dr.DRID DESC, ds.SignatureID DESC;
        END;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Approved')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RECEIVING_REPORT',
                @DocumentID,
                'Approved',
                N'Approved by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                30
            FROM dbo.INVENTORY_LOGS l
            INNER JOIN dbo.PURCHASE_REQUESTS pr
                ON l.ReferenceType = 'REPLENISHMENT'
               AND pr.RepFID = l.ReferenceID
            INNER JOIN dbo.PURCHASE_ORDERS po
                ON po.PRID = pr.PRID
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'PURCHASE_ORDER'
               AND ds.DocumentID = po.POID
               AND ds.Stage = 'Approved'
               AND ds.IsActive = 1
            WHERE l.InventoryLogID = @DocumentID
            ORDER BY po.POID DESC, ds.SignatureID DESC;
        END;
    END;

    /*  REPLENISHMENT_REQUEST (@DocumentID = RepFID):
           Requested -> fallback to OriginRequisition Requested
           Inventory -> fallback to latest RECEIVING_REPORT Received for this RepFID */
    IF @DocumentType = 'REPLENISHMENT_REQUEST'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Requested')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'REPLENISHMENT_REQUEST',
                @DocumentID,
                'Requested',
                N'Requested by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                10
            FROM dbo.REPLENISHMENT_REQUESTS rr
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'REQUISITION'
               AND ds.DocumentID = rr.OriginRequisitionID
               AND ds.Stage = 'Requested'
               AND ds.IsActive = 1
            WHERE rr.RepFID = @DocumentID
              AND rr.OriginRequisitionID IS NOT NULL
            ORDER BY ds.SignatureID DESC;
        END;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Inventory')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'REPLENISHMENT_REQUEST',
                @DocumentID,
                'Inventory',
                N'Inventory staff',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                15
            FROM dbo.INVENTORY_LOGS l
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'RECEIVING_REPORT'
               AND ds.DocumentID = l.InventoryLogID
               AND ds.Stage = 'Received'
               AND ds.IsActive = 1
            WHERE l.ReferenceType = 'REPLENISHMENT'
              AND l.ReferenceID = @DocumentID
              AND l.TransactionType = 'Stock In'
            ORDER BY l.InventoryLogID DESC, ds.SignatureID DESC;
        END;
    END;

    /*  STOCK_CARD (@DocumentID = ItemID):
           Custodian -> fallback to latest RECEIVING_REPORT Received for this ItemID  */
    IF @DocumentType = 'STOCK_CARD'
       AND NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Custodian')
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'STOCK_CARD',
            @DocumentID,
            'Custodian',
            N'Inventory custodian',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            20
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'RECEIVING_REPORT'
           AND ds.DocumentID = l.InventoryLogID
           AND ds.Stage = 'Received'
           AND ds.IsActive = 1
        WHERE l.ItemID = @DocumentID
        ORDER BY l.InventoryLogID DESC, ds.SignatureID DESC;
    END;

    SELECT
        SignatureID,
        DocumentType,
        DocumentID,
        Stage,
        StageLabel,
        SignerUserID,
        SignerName,
        SignerRole,
        SignatureImage,
        DocumentHash,
        SignedAt,
        IsHashValid
    FROM @Result
    ORDER BY SortOrder, SignedAt;
END;
GO
