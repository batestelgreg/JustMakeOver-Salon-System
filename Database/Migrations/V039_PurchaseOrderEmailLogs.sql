USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO


IF OBJECT_ID(N'dbo.EMAIL_LOGS', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.EMAIL_LOGS
    (
        EmailLogID BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_EMAIL_LOGS PRIMARY KEY,
        POID INT NOT NULL,
        EmailType VARCHAR(30) NOT NULL
            CONSTRAINT DF_EMAIL_LOGS_EmailType DEFAULT ('PURCHASE_ORDER'),
        FollowupID INT NULL,
        RecipientEmail NVARCHAR(255) NOT NULL,
        Subject NVARCHAR(300) NOT NULL,
        EmailStatus VARCHAR(20) NOT NULL
            CONSTRAINT DF_EMAIL_LOGS_EmailStatus DEFAULT ('Pending'),
        SentAt DATETIME2(0) NULL,
        ErrorMessage NVARCHAR(1000) NULL,
        TriggeredByUserID INT NOT NULL,
        CreatedAt DATETIME2(0) NOT NULL
            CONSTRAINT DF_EMAIL_LOGS_CreatedAt DEFAULT (SYSDATETIME()),
        CONSTRAINT CK_EMAIL_LOGS_Status CHECK (EmailStatus IN ('Pending', 'Sent', 'Failed'))
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_EMAIL_LOGS_PO'
)
    ALTER TABLE dbo.EMAIL_LOGS
        ADD CONSTRAINT FK_EMAIL_LOGS_PO
        FOREIGN KEY (POID) REFERENCES dbo.PURCHASE_ORDERS (POID);
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_EMAIL_LOGS_TriggeredBy'
)
    ALTER TABLE dbo.EMAIL_LOGS
        ADD CONSTRAINT FK_EMAIL_LOGS_TriggeredBy
        FOREIGN KEY (TriggeredByUserID) REFERENCES dbo.USERS (UserID);
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_EMAIL_LOGS_POID_CreatedAt'
      AND object_id = OBJECT_ID(N'dbo.EMAIL_LOGS')
)
    CREATE INDEX IX_EMAIL_LOGS_POID_CreatedAt
        ON dbo.EMAIL_LOGS (POID, EmailType, CreatedAt DESC, EmailLogID DESC);
GO


CREATE OR ALTER VIEW dbo.vw_PurchasingWorkspacePO
AS
SELECT
    po.POID,
    po.PRID,
    po.SupplierID,
    s.SupplierName,
    s.Email AS SupplierEmail,
    rr.RepFID,
    rr.OriginRequisitionID,
    rr.ItemID,
    i.ItemCode,
    i.ItemName,
    po.QuantityOrdered,
    po.UnitPrice,
    po.TotalAmount,
    po.Status,
    po.DateIssued,
    YEAR(po.DateIssued) AS BudgetYear,
    t.ExpectedDate,
    t.DispatchedAt,
    t.DecisionReason,
    ISNULL(t.ReceivedBeforeOrder, 0) AS ReceivedBeforeOrder,
    rr.QuantityReceived AS RepFQuantityReceived,
    ISNULL(a.AcceptedQuantity, 0) AS AcceptedQuantity,
    po.QuantityOrdered - ISNULL(a.AcceptedQuantity, 0)
        AS OutstandingQuantity,
    ISNULL(m.StockedQuantity, 0) AS StockedQuantity,
    em.EmailStatus,
    em.SentAt AS EmailSentAt,
    em.RecipientEmail AS EmailRecipient,
    em.ErrorMessage AS EmailErrorMessage
FROM dbo.PURCHASE_ORDERS po
INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
LEFT JOIN dbo.PURCHASING_PO_TRACKING t ON t.POID = po.POID
OUTER APPLY
(
    SELECT SUM(drd.QuantityAccepted) AS AcceptedQuantity
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd ON drd.DRID = dr.DRID
    WHERE dr.POID = po.POID
) a
OUTER APPLY
(
    SELECT SUM(rmd.QuantityReceived) AS StockedQuantity
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
    INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
    WHERE dr.POID = po.POID
      AND rm.InventoryUpdated = 1
) m
OUTER APPLY
(
    SELECT TOP (1)
        el.EmailStatus,
        el.SentAt,
        el.RecipientEmail,
        el.ErrorMessage
    FROM dbo.EMAIL_LOGS el
    WHERE el.POID = po.POID
      AND el.EmailType = 'PURCHASE_ORDER'
    ORDER BY el.EmailLogID DESC
) em;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_BeginEmailLog
    @ActorUserID INT,
    @POID INT,
    @EmailType VARCHAR(30) = 'PURCHASE_ORDER',
    @FollowupID INT = NULL,
    @Subject NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
        LEFT JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        LEFT JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND (
              p.PermissionCode IN ('purchasing.manage', 'requisitions.approve')
              OR r.RoleName IN (N'Admin', N'Manager')
          )
    )
        THROW 50550,
            'You do not have permission to send supplier emails.',
            1;

    DECLARE
        @POStatus VARCHAR(30),
        @SupplierName NVARCHAR(200),
        @RecipientEmail NVARCHAR(255);

    SELECT
        @POStatus = po.Status,
        @SupplierName = s.SupplierName,
        @RecipientEmail = LTRIM(RTRIM(ISNULL(s.Email, N'')))
    FROM dbo.PURCHASE_ORDERS po
    INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
    WHERE po.POID = @POID;

    IF @POStatus IS NULL
        THROW 50551, 'The purchase order could not be found.', 1;

    IF @EmailType = 'PURCHASE_ORDER'
       AND @POStatus IN ('Pending Approval', 'Rejected', 'Cancelled')
        THROW 50552,
            'Only approved purchase orders can be emailed to the supplier.',
            1;

    /* TSQL-side supplier email validation before MIME construction. */
    IF @RecipientEmail = N''
        THROW 50553,
            'This supplier has no email address on file. Update the supplier record under Suppliers first.',
            1;

    IF @RecipientEmail NOT LIKE N'%_@_%._%'
       OR CHARINDEX(N' ', @RecipientEmail) > 0
       OR CHARINDEX(N'@', @RecipientEmail, CHARINDEX(N'@', @RecipientEmail) + 1) > 0
        THROW 50554,
            'The supplier email address on file is not valid. Please update it under Suppliers first.',
            1;

    DECLARE @FinalSubject NVARCHAR(300) =
        ISNULL(NULLIF(LTRIM(RTRIM(@Subject)), N''),
               CONCAT(N'Purchase Order PO-', RIGHT('0000' + CAST(@POID AS VARCHAR(10)), 4)));

    INSERT INTO dbo.EMAIL_LOGS
    (
        POID,
        EmailType,
        FollowupID,
        RecipientEmail,
        Subject,
        EmailStatus,
        TriggeredByUserID,
        CreatedAt
    )
    VALUES
    (
        @POID,
        LEFT(ISNULL(NULLIF(@EmailType, ''), 'PURCHASE_ORDER'), 30),
        @FollowupID,
        @RecipientEmail,
        LEFT(@FinalSubject, 300),
        'Pending',
        @ActorUserID,
        SYSDATETIME()
    );

    DECLARE @EmailLogID BIGINT = SCOPE_IDENTITY();

    SELECT
        @EmailLogID AS EmailLogID,
        @POID AS POID,
        @SupplierName AS SupplierName,
        @RecipientEmail AS RecipientEmail,
        @POStatus AS POStatus,
        'Pending' AS EmailStatus;
END;
GO



CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_CompleteEmailLog
    @ActorUserID INT,
    @EmailLogID BIGINT,
    @EmailStatus VARCHAR(20),
    @ErrorMessage NVARCHAR(1000) = NULL,
    @MarkDispatched BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @EmailStatus NOT IN ('Sent', 'Failed')
        THROW 50555, 'EmailStatus must be Sent or Failed.', 1;

    DECLARE
        @POID INT,
        @EmailType VARCHAR(30),
        @FollowupID INT,
        @RecipientEmail NVARCHAR(255),
        @Now DATETIME2(0) = SYSDATETIME(),
        @CleanError NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(LEFT(@ErrorMessage, 1000))), N'');

    SELECT
        @POID = el.POID,
        @EmailType = el.EmailType,
        @FollowupID = el.FollowupID,
        @RecipientEmail = el.RecipientEmail
    FROM dbo.EMAIL_LOGS el
    WHERE el.EmailLogID = @EmailLogID;

    IF @POID IS NULL
        THROW 50556, 'The email log entry could not be found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.EMAIL_LOGS
        SET EmailStatus = @EmailStatus,
            SentAt = CASE WHEN @EmailStatus = 'Sent' THEN @Now ELSE NULL END,
            ErrorMessage = CASE WHEN @EmailStatus = 'Failed' THEN @CleanError ELSE NULL END
        WHERE EmailLogID = @EmailLogID;

        /* When a PO email succeeds and the PO is currently Approved,
           automatically transition it to Sent to Supplier and stamp DispatchedAt. */
        IF @EmailStatus = 'Sent'
           AND @EmailType = 'PURCHASE_ORDER'
           AND ISNULL(@MarkDispatched, 1) = 1
        BEGIN
            UPDATE dbo.PURCHASE_ORDERS
            SET Status = 'Sent to Supplier'
            WHERE POID = @POID
              AND Status = 'Approved';

            IF @@ROWCOUNT > 0
            BEGIN
                IF EXISTS (SELECT 1 FROM dbo.PURCHASING_PO_TRACKING WHERE POID = @POID)
                BEGIN
                    UPDATE dbo.PURCHASING_PO_TRACKING
                    SET DispatchedAt = ISNULL(DispatchedAt, @Now)
                    WHERE POID = @POID;
                END
                ELSE
                BEGIN
                    INSERT INTO dbo.PURCHASING_PO_TRACKING (POID, DispatchedAt)
                    VALUES (@POID, @Now);
                END;
            END;
        END;

        /* When a follow-up reminder email succeeds, mark the follow-up sent. */
        IF @EmailStatus = 'Sent'
           AND @EmailType = 'FOLLOW_UP'
           AND @FollowupID IS NOT NULL
        BEGIN
            UPDATE dbo.PURCHASING_FOLLOWUPS
            SET SentAt = ISNULL(SentAt, @Now),
                SentByUserID = ISNULL(SentByUserID, @ActorUserID)
            WHERE FollowupID = @FollowupID;
        END;

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
            CASE WHEN @EmailStatus = 'Sent' THEN 'PO_EMAIL_SENT' ELSE 'PO_EMAIL_FAILED' END,
            LEFT(
                CASE
                    WHEN @EmailStatus = 'Sent' AND @EmailType = 'FOLLOW_UP'
                        THEN CONCAT(N'Sent follow-up reminder email for PO #', @POID, N' to ', @RecipientEmail, N'.')
                    WHEN @EmailStatus = 'Sent'
                        THEN CONCAT(N'Sent Purchase Order PO-', RIGHT('0000' + CAST(@POID AS VARCHAR(10)), 4), N' via email to ', @RecipientEmail, N'.')
                    ELSE CONCAT(N'Failed to send email for PO-', RIGHT('0000' + CAST(@POID AS VARCHAR(10)), 4), N' to ', @RecipientEmail, N': ', ISNULL(@CleanError, N'SMTP error'))
                END,
                500
            )
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        el.EmailLogID,
        el.POID,
        el.EmailType,
        el.EmailStatus,
        el.SentAt,
        el.RecipientEmail,
        el.ErrorMessage
    FROM dbo.EMAIL_LOGS el
    WHERE el.EmailLogID = @EmailLogID;
END;
GO
