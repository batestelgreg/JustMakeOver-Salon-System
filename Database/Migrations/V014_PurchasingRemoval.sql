/*
    V014_PurchasingRemoval.sql

    Allows:
    - Removing an Open Purchase Request with no PO history.
    - Removing quotations from an Open PR with no PO history.

    Removing a PR also removes its quotations.
    Its replenishment request remains unchanged.

    Existing Purchasing actions are forwarded to V012.
    Re-runnable: ang procedure kay CREATE OR ALTER.
*/

USE JustMakeOverSalonDB;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithRemoval
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Existing actions continue through the original procedure.
    IF @Action IS NULL
       OR @Action NOT IN ('RemovePR', 'RemoveQuotation')
    BEGIN
        EXEC dbo.usp_PurchasingWorkspace_Action
            @ActorUserID = @ActorUserID,
            @Action = @Action,
            @Payload = @Payload;

        RETURN;
    END;

    IF @Payload IS NULL OR ISJSON(@Payload) <> 1
        THROW 50600, 'Invalid purchasing request.', 1;

    -- Validate the signed-in user's current permissions.
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = r.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND r.IsActive = 1
          AND p.PermissionCode = N'purchasing.manage'
    )
        THROW 50601,
            'Purchasing management permission is required.', 1;

    DECLARE @PRID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID'));

    DECLARE @QuotationID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.quotationID'));

    DECLARE @LockResult INT;
    DECLARE @ResultID INT;
    DECLARE @Message NVARCHAR(300);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Share V012's lock to prevent removal during PO creation.
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50602,
                'Purchasing is busy. Please try again.', 1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            -- Resolve the quotation's actual PR from the database.
            SET @PRID = NULL;

            SELECT @PRID = PRID
            FROM dbo.SUPPLIER_QUOTATIONS WITH (UPDLOCK, HOLDLOCK)
            WHERE QuotationID = @QuotationID;

            IF @PRID IS NULL
                THROW 50603,
                    'This quotation no longer exists.', 1;
        END;

        -- Approved, rejected, or closed PRs cannot be removed.
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
              AND Status = 'Open'
        )
            THROW 50604,
                'Only an open Purchase Request can be changed.', 1;

        -- Protect records with any PO history.
        -- This includes rejected and cancelled Purchase Orders.
        IF EXISTS
        (
            SELECT 1
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
        )
        OR EXISTS
        (
            SELECT 1
            FROM dbo.PO_PR_Mapping WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
        )
            THROW 50605,
                'Records with Purchase Order history cannot be removed.', 1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE QuotationID = @QuotationID
              AND PRID = @PRID;

            -- Require comparison again after a quotation is removed.
            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            SET @ResultID = @QuotationID;
            SET @Message =
                N'Quotation removed. Compare the remaining quotations again.';
        END
        ELSE
        BEGIN
            -- Delete dependent quotations before deleting the PR.
            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE PRID = @PRID;

            DELETE FROM dbo.PURCHASE_REQUESTS
            WHERE PRID = @PRID;

            /*
                Preserve the replenishment request.

                V012 displays it again when:
                - Its status is Pending.
                - It has an outstanding quantity.
                - It no longer has a Purchase Request.
            */
            SET @ResultID = @PRID;
            SET @Message =
                N'Purchase Request and its quotations removed.';
        END;

        -- Keep an audit entry for the removal.
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
            'PURCHASING_ACTION',
            CONCAT(
                @Action,
                '; PR=', @PRID,
                '; Quotation=', @QuotationID,
                '; ', @Message
            )
        );

        COMMIT TRANSACTION;

        SELECT
            @ResultID AS ID,
            @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO