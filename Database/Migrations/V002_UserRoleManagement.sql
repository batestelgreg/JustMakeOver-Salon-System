/* ============================================================
   V002 — User & Role Management
   Adds management procedures for user accounts and security roles.
   Conventions follow V001: permission checks inside each procedure,
   English error messages, audit rows in USER_AUDIT_LOGS.
   ============================================================ */

/* ------------------------------------------------------------
   USER MANAGEMENT
   ------------------------------------------------------------ */

-- Kani nga procedure nagkuha sa tanang user accounts para sa listahan.
CREATE OR ALTER PROCEDURE usp_Users_GetAll
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
          AND p.PermissionCode = N'users.view'
    )
        THROW 50230, 'You do not have permission to view user accounts.', 1;

    SELECT u.UserID, u.LastName, u.FirstName, u.MiddleName, u.Username, u.Email,
           u.RoleID, r.RoleName, u.IsActive, u.MustChangePassword,
           u.FailedLoginAttempts, u.LockoutEnd, u.LastLogin, u.DateCreated
    FROM USERS u
    INNER JOIN ROLES r ON r.RoleID = u.RoleID
    ORDER BY u.IsActive DESC, u.LastName, u.FirstName;
END;
GO

-- Kani nga procedure nag-update sa basic details ug role sa usa ka user.
CREATE OR ALTER PROCEDURE usp_User_UpdateDetails
    @ActorUserID INT,
    @TargetUserID INT,
    @LastName NVARCHAR(50),
    @FirstName NVARCHAR(50),
    @MiddleName NVARCHAR(50) = NULL,
    @Email NVARCHAR(254),
    @RoleID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@LastName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@FirstName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@Email)), '') IS NULL
        THROW 50231, 'Complete user details are required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'users.update'
    )
        THROW 50232, 'You do not have permission to update user accounts.', 1;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @TargetUserID)
        THROW 50233, 'The user account could not be found.', 1;

    IF NOT EXISTS (SELECT 1 FROM ROLES WHERE RoleID = @RoleID AND IsActive = 1)
        THROW 50234, 'The selected role is not valid.', 1;

    IF EXISTS (
        SELECT 1 FROM USERS
        WHERE Email = @Email AND UserID <> @TargetUserID
    )
        THROW 50235, 'The email address is already used by another account.', 1;

    BEGIN TRANSACTION;

    UPDATE USERS
    SET LastName = @LastName,
        FirstName = @FirstName,
        MiddleName = @MiddleName,
        Email = @Email,
        RoleID = @RoleID
    WHERE UserID = @TargetUserID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @TargetUserID, 'USER_UPDATED',
            CONCAT('User details updated. New role ID: ', @RoleID, '.'));

    COMMIT TRANSACTION;
END;
GO

-- Kani nga procedure nag-activate o nag-deactivate sa user account.
CREATE OR ALTER PROCEDURE usp_User_SetActive
    @ActorUserID INT,
    @TargetUserID INT,
    @IsActive BIT
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
          AND p.PermissionCode = N'users.deactivate'
    )
        THROW 50236, 'You do not have permission to activate or deactivate accounts.', 1;

    IF @TargetUserID = @ActorUserID
        THROW 50237, 'You cannot change the status of your own account.', 1;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @TargetUserID)
        THROW 50233, 'The user account could not be found.', 1;

    -- Kani nga guard kay nagdili sa pag-deactivate sa kataposang aktibong Admin.
    IF @IsActive = 0
       AND EXISTS (
           SELECT 1 FROM USERS t
           INNER JOIN ROLES r ON r.RoleID = t.RoleID
           WHERE t.UserID = @TargetUserID AND r.RoleName = N'Admin'
       )
       AND (
           SELECT COUNT(*) FROM USERS others
           INNER JOIN ROLES r ON r.RoleID = others.RoleID
           WHERE others.UserID <> @TargetUserID
             AND others.IsActive = 1
             AND r.RoleName = N'Admin'
       ) = 0
        THROW 50238, 'At least one active Admin account must remain.', 1;

    BEGIN TRANSACTION;

    UPDATE USERS
    SET IsActive = @IsActive
    WHERE UserID = @TargetUserID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @TargetUserID,
            CASE WHEN @IsActive = 1 THEN 'USER_ACTIVATED' ELSE 'USER_DEACTIVATED' END,
            'User account status was changed.');

    COMMIT TRANSACTION;
END;
GO

-- Kani nga procedure gitugotan ang Admin nga mo-reset sa password sa user.
CREATE OR ALTER PROCEDURE usp_User_AdminResetPassword
    @ActorUserID INT,
    @TargetUserID INT,
    @NewHash VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(@NewHash, '') IS NULL
        THROW 50239, 'A new password hash is required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'users.update'
    )
        THROW 50232, 'You do not have permission to update user accounts.', 1;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @TargetUserID)
        THROW 50233, 'The user account could not be found.', 1;

    BEGIN TRANSACTION;

    UPDATE USERS
    SET PasswordHash = @NewHash,
        MustChangePassword = 1,
        PasswordChangedAt = SYSUTCDATETIME(),
        FailedLoginAttempts = 0,
        LockoutEnd = NULL
    WHERE UserID = @TargetUserID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @TargetUserID, 'PASSWORD_RESET',
            'Password was reset by an administrator.');

    COMMIT TRANSACTION;
END;
GO

/* ------------------------------------------------------------
   ROLE & PERMISSION MANAGEMENT
   ------------------------------------------------------------ */

-- Kani nga procedure nagkuha sa tanang roles ug ilang permissions.
CREATE OR ALTER PROCEDURE usp_Roles_GetAll
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
          AND p.PermissionCode = N'roles.view'
    )
        THROW 50240, 'You do not have permission to view roles.', 1;

    SELECT r.RoleID, r.RoleName, r.Description, r.IsActive,
           (SELECT COUNT(*) FROM USERS u
            WHERE u.RoleID = r.RoleID AND u.IsActive = 1) AS ActiveUserCount,
           STUFF((
               SELECT ',' + p.PermissionCode
               FROM ROLE_PERMISSIONS rp
               INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
               WHERE rp.RoleID = r.RoleID
               ORDER BY p.PermissionCode
               FOR XML PATH(''), TYPE
           ).value('.', 'NVARCHAR(MAX)'), 1, 1, '') AS PermissionCodes
    FROM ROLES r
    ORDER BY r.RoleID;
END;
GO

-- Kani nga procedure nagkuha sa tanang permission definitions.
CREATE OR ALTER PROCEDURE usp_Permissions_GetAll
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
          AND p.PermissionCode = N'roles.view'
    )
        THROW 50240, 'You do not have permission to view roles.', 1;

    SELECT PermissionID, PermissionCode, Description
    FROM PERMISSIONS
    ORDER BY PermissionCode;
END;
GO

-- Kani nga procedure nag-himo og bag-ong role nga may permissions.
CREATE OR ALTER PROCEDURE usp_Role_Create
    @ActorUserID INT,
    @RoleName NVARCHAR(50),
    @Description NVARCHAR(200) = NULL,
    @PermissionCodes NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@RoleName)), '') IS NULL
        THROW 50241, 'A role name is required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50242, 'You do not have permission to manage roles.', 1;

    IF EXISTS (SELECT 1 FROM ROLES WHERE RoleName = @RoleName)
        THROW 50243, 'A role with this name already exists.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM STRING_SPLIT(@PermissionCodes, ',') s
        WHERE LTRIM(RTRIM(s.value)) <> ''
    )
        THROW 50244, 'Select at least one permission for the role.', 1;

    IF EXISTS (
        SELECT 1 FROM STRING_SPLIT(@PermissionCodes, ',') s
        WHERE NOT EXISTS (
            SELECT 1 FROM PERMISSIONS p
            WHERE p.PermissionCode = LTRIM(RTRIM(s.value)))
    )
        THROW 50245, 'One of the selected permissions is not valid.', 1;

    BEGIN TRANSACTION;

    INSERT INTO ROLES (RoleName, Description, IsActive)
    VALUES (@RoleName, @Description, 1);

    DECLARE @NewRoleID INT = SCOPE_IDENTITY();

    INSERT INTO ROLE_PERMISSIONS (RoleID, PermissionID)
    SELECT @NewRoleID, p.PermissionID
    FROM STRING_SPLIT(@PermissionCodes, ',') s
    INNER JOIN PERMISSIONS p ON p.PermissionCode = LTRIM(RTRIM(s.value));

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, NULL, 'ROLE_CREATED',
            CONCAT('Role created: ', @RoleName, '.'));

    COMMIT TRANSACTION;

    SELECT CAST(@NewRoleID AS INT) AS NewRoleID;
END;
GO

-- Kani nga procedure nag-update sa role details ug status.
CREATE OR ALTER PROCEDURE usp_Role_Update
    @ActorUserID INT,
    @RoleID INT,
    @RoleName NVARCHAR(50),
    @Description NVARCHAR(200) = NULL,
    @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@RoleName)), '') IS NULL
        THROW 50241, 'A role name is required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50242, 'You do not have permission to manage roles.', 1;

    IF NOT EXISTS (SELECT 1 FROM ROLES WHERE RoleID = @RoleID)
        THROW 50246, 'The role could not be found.', 1;

    IF EXISTS (
        SELECT 1 FROM ROLES
        WHERE RoleName = @RoleName AND RoleID <> @RoleID
    )
        THROW 50243, 'A role with this name already exists.', 1;

    -- Kani nga guard kay nagpanalipod sa built-in Admin role.
    IF @RoleID = 1 AND (@IsActive = 0 OR @RoleName <> N'Admin')
        THROW 50247, 'The built-in Admin role cannot be renamed or disabled.', 1;

    IF @IsActive = 0
       AND EXISTS (SELECT 1 FROM USERS WHERE RoleID = @RoleID AND IsActive = 1)
        THROW 50248, 'Reassign all active users before disabling this role.', 1;

    BEGIN TRANSACTION;

    UPDATE ROLES
    SET RoleName = @RoleName,
        Description = @Description,
        IsActive = @IsActive
    WHERE RoleID = @RoleID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, NULL, 'ROLE_UPDATED',
            CONCAT('Role updated: ', @RoleName, '.'));

    COMMIT TRANSACTION;
END;
GO

-- Kani nga procedure nag-replace sa tanang permissions sa usa ka role.
CREATE OR ALTER PROCEDURE usp_Role_SetPermissions
    @ActorUserID INT,
    @RoleID INT,
    @PermissionCodes NVARCHAR(MAX)
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
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50242, 'You do not have permission to manage roles.', 1;

    IF NOT EXISTS (SELECT 1 FROM ROLES WHERE RoleID = @RoleID)
        THROW 50246, 'The role could not be found.', 1;

    -- Kani nga guard kay nagpanalipod sa permissions sa built-in Admin role.
    IF @RoleID = 1
        THROW 50249, 'The permissions of the built-in Admin role cannot be changed.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM STRING_SPLIT(@PermissionCodes, ',') s
        WHERE LTRIM(RTRIM(s.value)) <> ''
    )
        THROW 50244, 'Select at least one permission for the role.', 1;

    IF EXISTS (
        SELECT 1 FROM STRING_SPLIT(@PermissionCodes, ',') s
        WHERE NOT EXISTS (
            SELECT 1 FROM PERMISSIONS p
            WHERE p.PermissionCode = LTRIM(RTRIM(s.value)))
    )
        THROW 50245, 'One of the selected permissions is not valid.', 1;

    BEGIN TRANSACTION;

    DELETE FROM ROLE_PERMISSIONS WHERE RoleID = @RoleID;

    INSERT INTO ROLE_PERMISSIONS (RoleID, PermissionID)
    SELECT @RoleID, p.PermissionID
    FROM STRING_SPLIT(@PermissionCodes, ',') s
    INNER JOIN PERMISSIONS p ON p.PermissionCode = LTRIM(RTRIM(s.value));

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, NULL, 'ROLE_PERMISSIONS_UPDATED',
            CONCAT('Permissions updated for role ID ', @RoleID, '.'));

    COMMIT TRANSACTION;
END;
GO
