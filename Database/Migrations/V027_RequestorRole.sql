/*
    V027_RequestorRole.sql

    Renames Staff to Requestor while preserving RoleID,
    assigned users, and existing permissions.

    Updates role assignment to use the Requestor role name.
*/

USE JustMakeOverSalonDB;
GO

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @OldRoleID INT =
    (
        SELECT RoleID
        FROM dbo.ROLES
        WHERE RoleName = N'Staff'
    );

    DECLARE @NewRoleID INT =
    (
        SELECT RoleID
        FROM dbo.ROLES
        WHERE RoleName = N'Requestor'
    );

    IF @OldRoleID IS NOT NULL
       AND @NewRoleID IS NOT NULL
       AND @OldRoleID <> @NewRoleID
    BEGIN
        ;THROW 50700,
            'Both Staff and Requestor roles exist. Reconcile them before running this migration.',
            1;
    END;

    IF @OldRoleID IS NULL AND @NewRoleID IS NULL
    BEGIN
        ;THROW 50701,
            'The Staff role was not found. Check the role setup before continuing.',
            1;
    END;

    IF @OldRoleID IS NOT NULL
    BEGIN
        UPDATE dbo.ROLES
        SET RoleName = N'Requestor',
            Description =
                N'Submits requisitions and acknowledges their delivered items.'
        WHERE RoleID = @OldRoleID;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.PERMISSIONS
        WHERE PermissionCode = N'delivery.view'
    )
    BEGIN
        ;THROW 50702,
            'Delivery permissions are missing. Apply the preceding migrations first.',
            1;
    END;

    INSERT INTO dbo.ROLE_PERMISSIONS
    (
        RoleID,
        PermissionID
    )
    SELECT
        r.RoleID,
        p.PermissionID
    FROM dbo.ROLES r
    CROSS JOIN dbo.PERMISSIONS p
    WHERE r.RoleName = N'Requestor'
      AND p.PermissionCode = N'delivery.view'
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          WHERE rp.RoleID = r.RoleID
            AND rp.PermissionID = p.PermissionID
      );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_AssignRole
    @ActorUserID INT,
    @TargetUserID INT,
    @NewRoleID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ActorRole NVARCHAR(50);
    DECLARE @NewRole NVARCHAR(50);
    DECLARE @TargetRole NVARCHAR(50);

    SELECT @ActorRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON u.RoleID = r.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    SELECT @NewRole = RoleName
    FROM dbo.ROLES
    WHERE RoleID = @NewRoleID
      AND IsActive = 1;

    SELECT @TargetRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON u.RoleID = r.RoleID
    WHERE u.UserID = @TargetUserID;

    IF @ActorRole IS NULL
        THROW 50001, 'Invalid or inactive account.', 1;

    IF @ActorRole <> N'Admin'
        THROW 50002, 'Only Admin can assign user roles.', 1;

    IF @NewRole IS NULL
        THROW 50003, 'Invalid role.', 1;

    IF @NewRole NOT IN
    (
        N'Manager',
        N'Inventory Staff',
        N'Purchasing Staff',
        N'Requestor'
    )
        THROW 50004, 'Admin cannot assign this role.', 1;

    IF @TargetRole IS NULL
        THROW 50005, 'Target user was not found.', 1;

    IF @TargetRole = N'Admin'
        THROW 50006,
            'Admin accounts cannot be changed through this procedure.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.USERS
    SET RoleID = @NewRoleID
    WHERE UserID = @TargetUserID;

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;

        THROW 50007, 'Target user was not found.', 1;
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
        @TargetUserID,
        'ROLE_CHANGED',
        CONCAT('Role changed to ', @NewRole)
    );

    COMMIT TRANSACTION;
END;
GO

SELECT
    r.RoleID,
    r.RoleName,
    r.IsActive,
    COUNT(u.UserID) AS AssignedUsers
FROM dbo.ROLES r
LEFT JOIN dbo.USERS u
    ON u.RoleID = r.RoleID
WHERE r.RoleName IN (N'Staff', N'Requestor')
GROUP BY
    r.RoleID,
    r.RoleName,
    r.IsActive;
GO