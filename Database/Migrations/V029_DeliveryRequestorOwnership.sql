/*
    V029_DeliveryRequestorOwnership.sql

    Apply after V028.

    Clarification:
      "Requestor" means the owner of the requisition,
      not a separate user role.

    Changes:
      1. Restore the Staff role name.
      2. Restore Staff in the role-assignment procedure.
      3. Give the existing application roles Delivery page access.
      4. Allow the receipt owner or Admin to acknowledge a delivery.

    V028 management restrictions remain:
      Inventory Staff / Admin generate, issue, correct, and re-issue.

    Existing discrepancy and completion checks remain unchanged.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. RESTORE STAFF ROLE NAME
   Preserve RoleID, assigned users, and existing permissions.
   ============================================================ */

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @StaffRoleID INT =
    (
        SELECT RoleID
        FROM dbo.ROLES
        WHERE RoleName = N'Staff'
    );

    DECLARE @RequestorRoleID INT =
    (
        SELECT RoleID
        FROM dbo.ROLES
        WHERE RoleName = N'Requestor'
    );

    IF @StaffRoleID IS NOT NULL
       AND @RequestorRoleID IS NOT NULL
    BEGIN
        ;THROW 50703,
            'Both Staff and Requestor roles exist. Reconcile these roles before applying this migration.',
            1;
    END;

    IF @StaffRoleID IS NULL
       AND @RequestorRoleID IS NULL
    BEGIN
        ;THROW 50704,
            'Neither Staff nor Requestor role was found.',
            1;
    END;

    IF @RequestorRoleID IS NOT NULL
    BEGIN
        UPDATE dbo.ROLES
        SET RoleName = N'Staff',
            Description =
                N'Submits requisitions and acknowledges their own delivered items.'
        WHERE RoleID = @RequestorRoleID;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.PERMISSIONS
        WHERE PermissionCode = N'delivery.view'
    )
    BEGIN
        ;THROW 50702,
            'Delivery permissions are missing. Apply preceding migrations first.',
            1;
    END;

    /*
        These roles can open Delivery.

        Viewing the page does not grant permission to issue items
        or acknowledge another user's receipt.
    */
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
    WHERE r.RoleName IN
    (
        N'Admin',
        N'Manager',
        N'Inventory Staff',
        N'Purchasing Staff',
        N'Staff'
    )
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

/* ============================================================
   2. ACKNOWLEDGEMENT ACCESS BASED ON RECEIPT OWNERSHIP

   Any active receipt owner can acknowledge their own receipt.
   Admin retains access to all receipts.

   V028 procedures and GetOverview already call this function.
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
              OR d.RequestorUserID = @ActorUserID
          )
    )
        SET @Allowed = 1;

    RETURN @Allowed;
END;
GO

/* ============================================================
   3. RESTORE STAFF IN ROLE ASSIGNMENT
   ============================================================ */

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
        ON r.RoleID = u.RoleID
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
        ON r.RoleID = u.RoleID
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
        N'Staff'
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

/* Verification: Staff should exist instead of Requestor. */

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