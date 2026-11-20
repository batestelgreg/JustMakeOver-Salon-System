/*
   V020 - Missing stored procedures (naa sa live DB, wala sa repo)

   Kini nga migration kay nagbalik sa 7 ka stored procedures nga
   gihimo diretso sa SSMS ug wala maapil sa bisan unsang migration.
   Kung magbuild og fresh database gikan sa Database/Migrations,
   kining mga proc kay "Could not find stored procedure" ang error.

     A. Login ug session (core - kung wala ni, dili makalogin):
        - dbo.usp_Login_GetUser
        - dbo.usp_Login_Failed
        - dbo.usp_Login_Succeeded
        - dbo.usp_GetUserPermissions

     B. User role assignment (gamit sa Users page):
        - dbo.usp_User_AssignRole

     C. Purchasing (gamit sa V012 usp_PurchasingWorkspace_Action):
        - dbo.usp_Purchasing_SetBudget   (Save budget)
        - dbo.usp_Purchasing_ApprovePO   (Approve PO)

   Kini idempotent: CREATE OR ALTER ra, walay DROP, walay data change.
   Ang logic kay pareho sa live DB - wala giusab ang rules, ang
   THROW numbers lang ang gidocument para masubay.

   THROW range:
     50001-50007  usp_User_AssignRole validation
     50310-50312  usp_Purchasing_SetBudget validation
     50320-50325  usp_Purchasing_ApprovePO validation
*/

USE JustMakeOverSalonDB;
GO

/* 
   A. LOGIN UG SESSION
    */

/* Kani nga procedure para makuha ang account details sa login.
   Apil na ang RoleName para kabalo ang app asa siya mo-redirect. */
CREATE OR ALTER PROCEDURE dbo.usp_Login_GetUser
    @Username NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.UserID,
        u.LastName,
        u.FirstName,
        u.MiddleName,
        u.Username,
        u.PasswordHash,
        u.Email,
        u.IsActive,
        u.FailedLoginAttempts,
        u.LockoutEnd,
        u.MustChangePassword,
        u.RoleID,
        r.RoleName

    FROM USERS u
    INNER JOIN ROLES r
        ON u.RoleID = r.RoleID

    WHERE u.Username = @Username;
END;
GO

/* Kani nga procedure para ma-record ang failed login attempt.
   Kung moabot og 5 ang failed attempts, 15 minutos nga lockout. */
CREATE OR ALTER PROCEDURE dbo.usp_Login_Failed
    @Username NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE USERS
    SET
        FailedLoginAttempts =
            CASE
                WHEN LockoutEnd IS NOT NULL
                     AND LockoutEnd <= SYSDATETIME()
                THEN 1
                ELSE FailedLoginAttempts + 1
            END,

        LockoutEnd =
            CASE
                WHEN LockoutEnd IS NOT NULL
                     AND LockoutEnd <= SYSDATETIME()
                THEN NULL
                WHEN FailedLoginAttempts + 1 >= 5
                THEN DATEADD(MINUTE, 15, SYSDATETIME())
                ELSE LockoutEnd
            END

    WHERE Username = @Username
      AND IsActive = 1;
END;
GO

/* Kani nga procedure para ma-reset ang failed attempts kung
   sakto ang password, ug ma-log ang LastLogin. */
CREATE OR ALTER PROCEDURE dbo.usp_Login_Succeeded
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE USERS
    SET
        FailedLoginAttempts = 0,
        LockoutEnd = NULL,
        LastLogin = SYSDATETIME()

    WHERE UserID = @UserID
      AND IsActive = 1
      AND (
          LockoutEnd IS NULL
          OR LockoutEnd <= SYSDATETIME()
      );

    SELECT @@ROWCOUNT AS RowsUpdated;
END;
GO

/* Kani nga procedure para makuha ang permission codes sa active user.
   Kini ang gigamit sa app para mag-gate sa mga button ug pages. */
CREATE OR ALTER PROCEDURE dbo.usp_GetUserPermissions
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.UserID,
        u.Username,
        r.RoleName,
        p.PermissionCode,
        p.Description

    FROM USERS u
    INNER JOIN ROLES r
        ON u.RoleID = r.RoleID
    INNER JOIN ROLE_PERMISSIONS rp
        ON r.RoleID = rp.RoleID
    INNER JOIN PERMISSIONS p
        ON rp.PermissionID = p.PermissionID

    WHERE u.UserID = @UserID
      AND u.IsActive = 1
      AND r.IsActive = 1;
END;
GO

/* 
   B. USER ROLE ASSIGNMENT
   */

/* Kani nga procedure para sa pag-assign og role sa user.
   Ang Admin pwede ra mo-assign og Manager, Inventory Staff,
   Purchasing Staff ug Staff - dili Admin (para walay privilege
   escalation) ug dili pwede usbon ang existing Admin account. */
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
    FROM USERS u
    INNER JOIN ROLES r
        ON u.RoleID = r.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    SELECT @NewRole = RoleName
    FROM ROLES
    WHERE RoleID = @NewRoleID
      AND IsActive = 1;

    SELECT @TargetRole = r.RoleName
    FROM USERS u
    INNER JOIN ROLES r
        ON u.RoleID = r.RoleID
    WHERE u.UserID = @TargetUserID;

    IF @ActorRole IS NULL
        THROW 50001, 'Invalid or inactive account.', 1;

    IF @ActorRole <> N'Admin'
        THROW 50002, 'Only Admin can assign user roles.', 1;

    IF @NewRole IS NULL
        THROW 50003, 'Invalid role.', 1;

    IF @NewRole NOT IN (
        N'Manager',
        N'Inventory Staff',
        N'Purchasing Staff',
        N'Staff'
    )
        THROW 50004, 'Admin cannot assign this role.', 1;

    IF @TargetRole IS NULL
        THROW 50005, 'Target user was not found.', 1;

    IF @TargetRole = N'Admin'
        THROW 50006, 'Admin accounts cannot be changed through this procedure.', 1;

    BEGIN TRANSACTION;

    UPDATE USERS
    SET RoleID = @NewRoleID
    WHERE UserID = @TargetUserID;

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50007, 'Target user was not found.', 1;
    END;

    INSERT INTO USER_AUDIT_LOGS (
        ActorUserID,
        TargetUserID,
        ActionType,
        Description
    )
    VALUES (
        @ActorUserID,
        @TargetUserID,
        'ROLE_CHANGED',
        CONCAT('Role changed to ', @NewRole)
    );

    COMMIT TRANSACTION;
END;
GO

/* 
   C. PURCHASING APPROVAL UG BUDGET
   */

/* Kani nga procedure nag-set sa annual purchasing budget.
   Admin ra ang makahimo, ug dili pwede ibutang ubos sa na-commit
   nga PO total para dili malapas ang budget. */
CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_SetBudget
    @BudgetYear INT,
    @BudgetAmount DECIMAL(14,2),
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @BudgetYear NOT BETWEEN 2000 AND 2100 OR @BudgetAmount < 0
        THROW 50310, 'The budget year or amount is invalid.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM USERS u INNER JOIN ROLES r ON r.RoleID = u.RoleID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1 AND r.IsActive = 1 AND r.RoleName = N'Admin'
    )
        THROW 50311, 'Only an administrator can set the purchasing budget.', 1;

    IF EXISTS (
        SELECT 1 FROM PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    ) AND @BudgetAmount < (
        SELECT ISNULL(SUM(TotalAmount), 0) FROM PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    )
        THROW 50312, 'The budget cannot be set below the total committed purchase orders.', 1;

    -- Kini nga MERGE kay para isa ra ka row matag tuig (upsert).
    MERGE PURCHASE_BUDGETS AS target
    USING (SELECT @BudgetYear AS BudgetYear) AS source
       ON target.BudgetYear = source.BudgetYear
    WHEN MATCHED THEN UPDATE SET BudgetAmount = @BudgetAmount, IsActive = 1, UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT (BudgetYear, BudgetAmount, IsActive, CreatedByUserID)
         VALUES (@BudgetYear, @BudgetAmount, 1, @ActorUserID);
END;
GO

/* Kani nga procedure para i-approve ang PO human sa budget ug
   permission check. Admin/Manager ra, ug dapat Pending Approval pa
   ang PO. Kung mosobra sa remaining annual budget, DILI mo-approve. */
CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_ApprovePO
    @POID INT,
    @ApproverUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (
            SELECT 1 FROM USERS u INNER JOIN ROLES r ON r.RoleID = u.RoleID
            WHERE u.UserID = @ApproverUserID AND u.IsActive = 1 AND r.IsActive = 1
              AND r.RoleName IN (N'Admin', N'Manager')
        )
            THROW 50320, 'Only an Admin or Manager can approve the purchase order.', 1;

        DECLARE @Amount DECIMAL(12,2), @BudgetYear INT, @Status VARCHAR(30), @BudgetAmount DECIMAL(14,2), @Committed DECIMAL(14,2);
        SELECT @Amount = TotalAmount, @BudgetYear = YEAR(DateIssued), @Status = Status
        FROM PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE POID = @POID;

        IF @Amount IS NULL
            THROW 50321, 'The purchase order could not be found.', 1;
        IF @Status <> 'Pending Approval'
            THROW 50322, 'The purchase order (PO) must be in Pending Approval status.', 1;

        SELECT @BudgetAmount = BudgetAmount
        FROM PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
        WHERE BudgetYear = @BudgetYear AND IsActive = 1;

        IF @BudgetAmount IS NULL
            THROW 50323, 'The approved budget for this year has not been configured yet.', 1;

        -- Kani nga committed total kay ang mga PO nga naaprobahan na
        -- karong tuiga, para makita ang remaining budget.
        SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
        FROM PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered');

        IF @Committed + @Amount > @BudgetAmount
            THROW 50324, 'The purchase order exceeds the remaining annual budget.', 1;

        UPDATE PURCHASE_ORDERS
        SET Status = 'Approved', ApprovedByUserID = @ApproverUserID
        WHERE POID = @POID AND Status = 'Pending Approval';

        IF @@ROWCOUNT <> 1
            THROW 50325, 'The purchase order could not be updated.', 1;

        -- Kini nga update kay para ma-approve usab ang linked PR(s).
        UPDATE PURCHASE_REQUESTS
        SET Status = 'Approved'
        WHERE PRID IN (SELECT PRID FROM PO_PR_Mapping WHERE POID = @POID)
           OR PRID = (SELECT PRID FROM PURCHASE_ORDERS WHERE POID = @POID);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
