/* ================================================================
   JustMakeOverSalonDB - Migration V001
   Kani nga migration kay nagdugang mga procedures para sa user
   management, audit logging ug dashboard summary. Kani nga mga
   procedures kay gigamit sa C# backend, dili sa frontend.
   ================================================================ */

USE JustMakeOverSalonDB;
GO

-- Kani nga procedure para mag-himo og bag-ong user account ang Admin.
CREATE OR ALTER PROCEDURE usp_User_Create
    @ActorUserID INT,
    @LastName NVARCHAR(50),
    @FirstName NVARCHAR(50),
    @MiddleName NVARCHAR(50) = NULL,
    @Username NVARCHAR(50),
    @PasswordHash VARCHAR(255),
    @Email NVARCHAR(254),
    @RoleID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga validations kay para sa basic completeness sa user details.
    IF NULLIF(LTRIM(RTRIM(@LastName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@FirstName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@Username)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@PasswordHash)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@Email)), '') IS NULL
        THROW 50220, 'Complete user details are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM USERS u INNER JOIN ROLES r ON r.RoleID = u.RoleID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND r.IsActive = 1 AND r.RoleName = N'Admin'
    )
        THROW 50221, 'Only an Admin can create user accounts.', 1;

    IF NOT EXISTS (SELECT 1 FROM ROLES WHERE RoleID = @RoleID AND IsActive = 1)
        THROW 50222, 'The selected role is not valid.', 1;

    IF EXISTS (SELECT 1 FROM USERS WHERE Username = @Username)
        THROW 50223, 'The username is already taken.', 1;

    IF EXISTS (SELECT 1 FROM USERS WHERE Email = @Email)
        THROW 50224, 'The email address is already used by another account.', 1;

    BEGIN TRANSACTION;

    INSERT INTO USERS (LastName, FirstName, MiddleName, Username, PasswordHash, Email, RoleID)
    VALUES (@LastName, @FirstName, @MiddleName, @Username, @PasswordHash, @Email, @RoleID);

    DECLARE @NewUserID INT = SCOPE_IDENTITY();

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @NewUserID, 'USER_CREATED',
            CONCAT('User account created with role ID ', @RoleID, '.'));

    COMMIT TRANSACTION;
END;
GO

-- Kani nga procedure para i-update ang password hash sa user.
CREATE OR ALTER PROCEDURE usp_User_ChangePassword
    @UserID INT,
    @NewHash VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@NewHash)), '') IS NULL
        THROW 50226, 'A new password hash is required.', 1;

    UPDATE USERS
    SET
        PasswordHash = @NewHash,
        MustChangePassword = 0,
        PasswordChangedAt = SYSDATETIME()
    WHERE UserID = @UserID
      AND IsActive = 1;

    -- Kani nga check kay para mahibaw-an kung walay nabag-o nga account.
    IF @@ROWCOUNT = 0
        THROW 50227, 'The password could not be changed for this account.', 1;
END;
GO

-- Kani nga procedure para mo-log og user action sa audit trail.
CREATE OR ALTER PROCEDURE usp_Audit_LogAction
    @ActorUserID INT = NULL,
    @ActionType VARCHAR(50),
    @Description NVARCHAR(500) = NULL,
    @IPAddress VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@ActionType)), '') IS NULL
        THROW 50228, 'An action type is required for the audit log.', 1;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, ActionType, Description, IPAddress)
    VALUES (@ActorUserID, @ActionType, @Description, @IPAddress);
END;
GO

-- Kani nga procedure para makakuha og dashboard summary para sa user.
CREATE OR ALTER PROCEDURE usp_Dashboard_GetSummary
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga check kay para masiguro nga active ang user sa dashboard.
    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @UserID AND IsActive = 1)
        THROW 50229, 'The account is inactive or was not found.', 1;

    SELECT
        (SELECT COUNT(*) FROM ITEMS WHERE IsActive = 1) AS TotalItems,

        (SELECT COUNT(*)
         FROM ITEMS i
         INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
         WHERE i.IsActive = 1 AND inv.QuantityAvailable <= i.ReorderPoint) AS LowStockItems,

        (SELECT COUNT(*) FROM REQUISITIONS WHERE Status = 'Pending') AS PendingRequisitions,

        (SELECT COUNT(*) FROM REQUISITIONS WHERE Status = 'Approved') AS ApprovedRequisitions,

        (SELECT COUNT(*) FROM PURCHASE_REQUESTS WHERE Status IN ('Open', 'Pending Approval'))
            AS OpenPurchaseRequests,

        (SELECT COUNT(*) FROM PURCHASE_ORDERS WHERE Status = 'Pending Approval')
            AS PendingPurchaseOrders,

        (SELECT COUNT(*) FROM NOTIFICATIONS WHERE RecipientUserID = @UserID AND IsRead = 0)
            AS UnreadNotifications,

        (SELECT COUNT(*) FROM USERS WHERE IsActive = 1) AS ActiveUsers;
END;
GO

/* ================================================================
   Kani nga seed block kay para sa unang Admin account sa salon.
   Ang initial password kay 'Admin@123' ug kinahanglan usbon sa
   unya pag-login tungod sa MustChangePassword flag.
   ================================================================ */
IF NOT EXISTS (SELECT 1 FROM USERS WHERE Username = N'admin')
BEGIN
    INSERT INTO USERS (
        LastName, FirstName, Username, PasswordHash, Email, RoleID,
        IsActive, MustChangePassword
    )
    VALUES (
        N'Salon', N'Administrator', N'admin',
        'PBKDF2-SHA256:100000:wz84O/PrCQ8U1cHc/4XtJPpOzjjWoQwGC15rsQWFn88=:6YxPRCKpE+/UDO1tMiz4JXZ0QXOG+JoesICQCPgrMDYTt0h0Oto7ldfxw3FmUej4iR0uTr7ktht2cERgD9kW9Q==',
        N'admin@justmakeover.local',
        (SELECT RoleID FROM ROLES WHERE RoleName = N'Admin'),
        1, 1
    );
END;
GO
