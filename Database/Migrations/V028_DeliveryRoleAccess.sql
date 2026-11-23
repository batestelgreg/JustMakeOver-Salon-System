/*
    V028_DeliveryRoleAccess.sql

    

    Delivery access:
      Requestor:
        - Note discrepancy on their own receipt.
        - Sign and complete their own receipt.

      Inventory Staff:
        - Generate acknowledgement receipt.
        - Issue items.
        - Record correction.
        - Re-issue after correction.

      Admin:
        - All applicable actions.

    Existing allocation, signature, and stock-processing rules
    are retained.

    Re-runnable: CREATE OR ALTER.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. HELPER: INVENTORY STAFF / ADMIN MANAGEMENT ACCESS
   ============================================================ */

CREATE OR ALTER FUNCTION dbo.fn_DeliveryCanManage
(
    @ActorUserID INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Allowed BIT = 0;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
           AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = r.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND r.RoleName IN
          (
              N'Admin',
              N'Inventory Staff'
          )
          AND p.PermissionCode = N'delivery.manage'
    )
        SET @Allowed = 1;

    RETURN @Allowed;
END;
GO

/* ============================================================
   2. HELPER: REQUESTOR / ADMIN ACKNOWLEDGEMENT ACCESS
   ============================================================ */

CREATE OR ALTER FUNCTION dbo.fn_DeliveryCanAcknowledge
(
    @ActorUserID INT,
    @DeliveryID INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Allowed BIT = 0;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
           AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = r.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        INNER JOIN dbo.DELIVERIES d
            ON d.DeliveryID = @DeliveryID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.view'
          AND
          (
              r.RoleName = N'Admin'
              OR
              (
                  r.RoleName = N'Requestor'
                  AND d.RequestorUserID = @ActorUserID
              )
          )
    )
        SET @Allowed = 1;

    RETURN @Allowed;
END;
GO

/* ============================================================
   3. NOTE DISCREPANCY
   Requestor of this receipt or Admin.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_NoteDiscrepancy
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(1000)
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

    IF NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
        THROW 50407,
            'A discrepancy note is required.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50408,
            'A discrepancy can only be noted on an issued acknowledgement receipt.',
            1;

    /*
        A new discrepancy requires a new correction.
        Previous correction markers are cleared.
    */
    UPDATE dbo.DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes)),
        DiscrepancyResolvedAt = NULL,
        CorrectedAt = NULL,
        CorrectedByUserID = NULL,
        CorrectionNotes = NULL
    WHERE DeliveryID = @DeliveryID;

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
        'DELIVERY_DISCREPANCY',
        'Delivery discrepancy noted',
        'A discrepancy was noted on an acknowledgement receipt. The item may need replacement or record correction.',
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
        'DELIVERY_DISCREPANCY',
        CONCAT
        (
            'Discrepancy noted on acknowledgement receipt #',
            @DeliveryID,
            '.'
        )
    );
END;
GO

/* ============================================================
   4. RECORD CORRECTION
   Inventory Staff or Admin.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_RecordCorrection
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can record delivery corrections.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
        THROW 50419,
            'The correction details are required.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50408,
            'A correction can only be recorded on an issued acknowledgement receipt.',
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
            'Note the discrepancy first before recording a correction.',
            1;

    UPDATE dbo.DELIVERIES
    SET CorrectedAt = SYSDATETIME(),
        CorrectedByUserID = @ActorUserID,
        CorrectionNotes = LTRIM(RTRIM(@Notes))
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
        'DELIVERY_CORRECTED',
        CONCAT
        (
            'Item replacement/record correction recorded on acknowledgement receipt #',
            @DeliveryID,
            '.'
        )
    );
END;
GO

/* ============================================================
   5. RE-ISSUE
   Inventory Staff or Admin.

   Requires an open discrepancy and a recorded correction.
   Returns the same receipt to Generated for another issue.
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
   6. SIGN AND COMPLETE
   Requestor of this receipt or Admin.

   Completion remains blocked while a discrepancy is open.
   Existing stock deduction and fulfilment logic is retained.
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
   7. DELIVERY OVERVIEW
   Preserve the result-set column order used by the C# reader.

   CanAcknowledge is true only for:
      - Admin
      - Requestor who owns the receipt
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetOverview
    @ActorUserID INT
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
        THROW 50400,
            'You do not have permission to view deliveries.',
            1;

    /* Result set 1: fully allocated requisitions. */

    SELECT
        r.RequisitionID,
        CONCAT
        (
            reqUser.FirstName,
            ' ',
            reqUser.LastName
        ) AS RequestorName,
        r.RequestDate,
        r.RequiredDate,
        r.Justification,
        (
            SELECT STRING_AGG
            (
                CONCAT
                (
                    i.ItemName,
                    N' (Qty: ',
                    CAST
                    (
                        ISNULL
                        (
                            rd.QuantityApproved,
                            rd.QuantityRequested
                        ) AS NVARCHAR(20)
                    ),
                    N')'
                ),
                N'; '
            )
            WITHIN GROUP
            (
                ORDER BY rd.RequisitionDetailID
            )
            FROM dbo.REQUISITION_DETAILS rd
            INNER JOIN dbo.ITEMS i
                ON i.ItemID = rd.ItemID
            WHERE rd.RequisitionID = r.RequisitionID
        ) AS ItemsSummary
    FROM dbo.REQUISITIONS r
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = r.RequestorUserID
    WHERE r.Status = N'Approved'
      AND EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITION_DETAILS rd
          WHERE rd.RequisitionID = r.RequisitionID
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITION_DETAILS rd
          WHERE rd.RequisitionID = r.RequisitionID
            AND rd.Status IN
            (
                N'Pending',
                N'Partially Fulfilled'
            )
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.DELIVERIES d
          WHERE d.RequisitionID = r.RequisitionID
            AND d.Status IN
            (
                N'Generated',
                N'Issued'
            )
      )
    ORDER BY r.RequestDate;

    /* Result set 2: acknowledgement receipts. */

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
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        CONCAT
        (
            signedUser.FirstName,
            ' ',
            signedUser.LastName
        ) AS SignedByName,
        d.DiscrepancyNotes,
        d.Status,
        (
            SELECT STRING_AGG
            (
                CONCAT
                (
                    i.ItemName,
                    N' (Qty: ',
                    CAST(di.Quantity AS NVARCHAR(20)),
                    N')'
                ),
                N'; '
            )
            WITHIN GROUP
            (
                ORDER BY di.DeliveryItemID
            )
            FROM dbo.DELIVERY_ITEMS di
            INNER JOIN dbo.ITEMS i
                ON i.ItemID = di.ItemID
            WHERE di.DeliveryID = d.DeliveryID
        ) AS ItemsSummary,
        CAST
        (
            CASE
                WHEN d.ESignatureData IS NULL THEN 0
                ELSE 1
            END AS BIT
        ) AS HasSignature,
        CAST
        (
            CASE
                WHEN NULLIF
                     (
                         LTRIM(RTRIM(d.DiscrepancyNotes)),
                         N''
                     ) IS NOT NULL
                 AND d.DiscrepancyResolvedAt IS NULL
                    THEN 1
                ELSE 0
            END AS BIT
        ) AS HasUnresolvedDiscrepancy,
        d.DiscrepancyResolvedAt,
        dbo.fn_DeliveryCanAcknowledge
        (
            @ActorUserID,
            d.DeliveryID
        ) AS CanAcknowledge,
        d.CorrectedAt,
        d.CorrectionNotes,
        CONCAT
        (
            correctedUser.FirstName,
            ' ',
            correctedUser.LastName
        ) AS CorrectedByName
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    LEFT JOIN dbo.USERS correctedUser
        ON correctedUser.UserID = d.CorrectedByUserID
    ORDER BY
        d.GeneratedDate DESC,
        d.DeliveryID DESC;
END;
GO

/* ============================================================
   8. GENERATE ACKNOWLEDGEMENT RECEIPT
   Inventory Staff or Admin.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GenerateAR
    @ActorUserID INT,
    @RequisitionID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can generate acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
          AND Status = N'Approved'
    )
        THROW 50402,
            'Only an approved requisition can receive an acknowledgement receipt.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Generated',
              N'Issued'
          )
    )
        THROW 50403,
            'This requisition already has an open acknowledgement receipt.',
            1;

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
            'All requisition items must be fully allocated before generating an acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
    )
        THROW 50405,
            'This requisition has no items to deliver.',
            1;

    BEGIN TRANSACTION;

    DECLARE @MaxNum INT =
    (
        SELECT MAX
        (
            TRY_CAST
            (
                SUBSTRING(ARCode, 4, 10) AS INT
            )
        )
        FROM dbo.DELIVERIES
        WHERE ARCode LIKE 'AR-[0-9]%'
    );

    DECLARE @ARCode VARCHAR(30) =
        'AR-' +
        RIGHT
        (
            '0000' +
            CAST
            (
                ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)
            ),
            4
        );

    WHILE EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE ARCode = @ARCode
    )
    BEGIN
        SET @MaxNum = ISNULL(@MaxNum, 0) + 1;

        SET @ARCode =
            'AR-' +
            RIGHT
            (
                '0000' +
                CAST(@MaxNum AS VARCHAR(10)),
                4
            );
    END;

    DECLARE @RequestorUserID INT =
    (
        SELECT RequestorUserID
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
    );

    INSERT INTO dbo.DELIVERIES
    (
        ARCode,
        RequisitionID,
        RequestorUserID,
        GeneratedByUserID,
        GeneratedDate,
        Status
    )
    VALUES
    (
        @ARCode,
        @RequisitionID,
        @RequestorUserID,
        @ActorUserID,
        SYSDATETIME(),
        N'Generated'
    );

    DECLARE @DeliveryID INT = SCOPE_IDENTITY();

    INSERT INTO dbo.DELIVERY_ITEMS
    (
        DeliveryID,
        RequisitionDetailID,
        ItemID,
        Quantity
    )
    SELECT
        @DeliveryID,
        rd.RequisitionDetailID,
        rd.ItemID,
        ISNULL
        (
            rd.QuantityApproved,
            rd.QuantityRequested
        )
    FROM dbo.REQUISITION_DETAILS rd
    WHERE rd.RequisitionID = @RequisitionID;

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
        'DELIVERY_AR_GENERATED',
        CONCAT
        (
            'Acknowledgement receipt ',
            @ARCode,
            ' generated for requisition #',
            @RequisitionID,
            '.'
        )
    );

    COMMIT TRANSACTION;

    SELECT
        @DeliveryID AS DeliveryID,
        @ARCode AS ARCode;
END;
GO

/* ============================================================
   9. MARK ISSUED
   Inventory Staff or Admin.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_MarkIssued
    @ActorUserID INT,
    @DeliveryID INT
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

    UPDATE dbo.DELIVERIES
    SET Status = N'Issued',
        IssuedDate = SYSDATETIME()
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
        @ActorUserID,
        'DELIVERY_ISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' marked as issued.'
        )
    );
END;
GO