/*
    Automatically generates Purchasing delivery references.

    Existing supplier DR values remain unchanged.
    The new procedure forwards other actions to V014.
*/

USE JustMakeOverSalonDB;
GO

-- Create the sequence once.
IF OBJECT_ID(
    N'dbo.PurchasingDeliveryReferenceSequence',
    N'SO'
) IS NULL
BEGIN
    EXEC(N'
        CREATE SEQUENCE dbo.PurchasingDeliveryReferenceSequence
        AS BIGINT
        START WITH 1
        INCREMENT BY 1
        NO CYCLE;
    ');
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithDeliveryReference
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Preserve existing actions, including V014 removal actions.
    IF @Action IS NULL OR @Action <> 'RecordDR'
    BEGIN
        EXEC dbo.usp_PurchasingWorkspace_ActionWithRemoval
            @ActorUserID = @ActorUserID,
            @Action = @Action,
            @Payload = @Payload;

        RETURN;
    END;

    IF @Payload IS NULL OR ISJSON(@Payload) <> 1
        THROW 50620, 'Invalid delivery request.', 1;

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
        THROW 50621,
            'Purchasing management permission is required.', 1;

    DECLARE @LockResult INT;
    DECLARE @ReferenceNumber BIGINT;
    DECLARE @NumberText NVARCHAR(20);
    DECLARE @DeliveryReference NVARCHAR(100);

    DECLARE @Result TABLE
    (
        ID INT,
        Message NVARCHAR(300)
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Shares the existing Purchasing lock.
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50622,
                'Purchasing is busy. Please try again.', 1;

        -- Skip any matching references already stored in old records.
        WHILE 1 = 1
        BEGIN
            SELECT @ReferenceNumber =
                NEXT VALUE FOR dbo.PurchasingDeliveryReferenceSequence;

            SET @NumberText =
                CONVERT(NVARCHAR(20), @ReferenceNumber);

            SET @DeliveryReference =
                N'DR-'
                + CASE
                    WHEN LEN(@NumberText) < 6
                        THEN REPLICATE(N'0', 6 - LEN(@NumberText))
                    ELSE N''
                  END
                + @NumberText;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_DR_TRACKING
                WHERE SupplierDRNumber = @DeliveryReference
            )
                BREAK;
        END;

        -- Ignore any reference supplied by the browser.
        SET @Payload = JSON_MODIFY(
            @Payload,
            '$.drNumber',
            @DeliveryReference
        );

        -- V012 still validates the PO and delivery quantities.
        INSERT INTO @Result (ID, Message)
        EXEC dbo.usp_PurchasingWorkspace_ActionWithRemoval
            @ActorUserID = @ActorUserID,
            @Action = @Action,
            @Payload = @Payload;

        IF NOT EXISTS (SELECT 1 FROM @Result)
            THROW 50623,
                'The delivery operation returned no confirmation.', 1;

        COMMIT TRANSACTION;

        SELECT
            ID,
            Message,
            @DeliveryReference AS DeliveryReference
        FROM @Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO