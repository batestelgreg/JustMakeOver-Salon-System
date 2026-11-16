USE JustMakeOverSalonDB;
GO

-- Kani nga alter kay para ang Address kay nullable (optional man
-- kini sa UI). Re-running ni kay safe - ang nullable state mo-
-- persist na ug ang repeated ALTER kay no-op nga result.
ALTER TABLE SUPPLIERS ALTER COLUMN Address NVARCHAR(1000) NULL;
GO

CREATE OR ALTER PROCEDURE usp_Suppliers_GetAll
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
          AND p.PermissionCode IN (N'suppliers.view', N'purchasing.view', N'purchasing.manage')
    )
        THROW 50380, 'You do not have permission to view suppliers.', 1;

    SELECT s.SupplierID,
           s.SupplierCode,
           s.SupplierName,
           s.ContactPersonFirstName,
           s.ContactPersonMiddleName,
           s.ContactPersonLastName,
           s.Phone,
           s.Email,
           s.Address,
           s.IsActive,
           (SELECT COUNT(*) FROM SUPPLIER_QUOTATIONS q
            WHERE q.SupplierID = s.SupplierID) AS QuotationCount,
           (SELECT COUNT(*) FROM PURCHASE_ORDERS po
            WHERE po.SupplierID = s.SupplierID) AS PurchaseOrderCount
    FROM SUPPLIERS s
    ORDER BY s.SupplierName;
END;
GO

/* 2. SAVE SUPPLIER - create (SupplierID NULL) o update (fields +
      active status). Ang deactivation kay allowed bisan gi-
      reference sa quotations/POs (history intact ra - ang
      deactivated supplier dili na mo-gawas sa new quotation/
      PO selection sa Purchasing phase).
   Gate: suppliers.manage.
    */
CREATE OR ALTER PROCEDURE usp_Suppliers_Save
    @ActorUserID INT,
    @SupplierID INT = NULL,
    @SupplierName NVARCHAR(200) = NULL,
    @ContactPersonFirstName NVARCHAR(100) = NULL,
    @ContactPersonMiddleName NVARCHAR(100) = NULL,
    @ContactPersonLastName NVARCHAR(100) = NULL,
    @Phone VARCHAR(20) = NULL,
    @Email NVARCHAR(508) = NULL,
    @Address NVARCHAR(1000) = NULL,
    @IsActive BIT = NULL
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
          AND p.PermissionCode = N'suppliers.manage'
    )
        THROW 50381, 'You do not have permission to manage suppliers.', 1;

    -- Kani nga trim block kay para sa tanang text inputs.
    DECLARE @CleanName NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@SupplierName)), '');
    DECLARE @CleanFirst NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ContactPersonFirstName)), '');
    DECLARE @CleanMiddle NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ContactPersonMiddleName)), '');
    DECLARE @CleanLast NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ContactPersonLastName)), '');
    DECLARE @CleanPhone VARCHAR(20) = NULLIF(LTRIM(RTRIM(@Phone)), '');
    DECLARE @CleanEmail NVARCHAR(508) = NULLIF(LTRIM(RTRIM(@Email)), '');
    DECLARE @CleanAddress NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(@Address)), '');

    IF @SupplierID IS NULL
    BEGIN
        -- Kani nga create path: kinahanglan ang name, first name,
        -- last name ug phone. Ang email ug address kay optional.
        IF @CleanName IS NULL
            THROW 50382, 'The supplier name is required.', 1;

        IF @CleanFirst IS NULL OR @CleanLast IS NULL
            THROW 50383, 'The contact person first name and last name are required.', 1;

        IF @CleanPhone IS NULL
            THROW 50384, 'The contact phone number is required.', 1;

        IF LEN(@CleanPhone) > 20
            THROW 50385, 'The contact phone number must be 20 characters or fewer.', 1;

        IF @CleanEmail IS NOT NULL AND @CleanEmail NOT LIKE N'%_@_%._%'
            THROW 50386, 'The contact email address is not valid.', 1;

        IF EXISTS (SELECT 1 FROM SUPPLIERS WHERE SupplierName = @CleanName)
            THROW 50387, 'A supplier with this name already exists.', 1;

        -- Kani nga block kay para sa auto-generation sa SupplierCode
        -- (SUP-#### nga pattern, same approach sa ITM-#### sa items).
        DECLARE @MaxNum INT = (
            SELECT MAX(TRY_CAST(SUBSTRING(SupplierCode, 5, 10) AS INT))
            FROM SUPPLIERS
            WHERE SupplierCode LIKE 'SUP-[0-9]%'
        );

        DECLARE @Candidate VARCHAR(30) =
            'SUP-' + RIGHT('000' + CAST(ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)), 3);

        WHILE EXISTS (SELECT 1 FROM SUPPLIERS WHERE SupplierCode = @Candidate)
        BEGIN
            SET @MaxNum = ISNULL(@MaxNum, 0) + 1;
            SET @Candidate = 'SUP-' + RIGHT('000' + CAST(@MaxNum AS VARCHAR(10)), 3);
        END;

        INSERT INTO SUPPLIERS
            (SupplierCode, SupplierName, ContactPersonFirstName, ContactPersonMiddleName,
             ContactPersonLastName, Phone, Email, Address, IsActive)
        VALUES
            (@Candidate, @CleanName, @CleanFirst, @CleanMiddle,
             @CleanLast, @CleanPhone, @CleanEmail, @CleanAddress, 1);

        INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @ActorUserID, 'SUPPLIER_CREATED',
                CONCAT('Supplier ', @Candidate, ' (', @CleanName, ') was created.'));

        SELECT SCOPE_IDENTITY() AS SupplierID, @Candidate AS SupplierCode;
        RETURN;
    END;

    -- Kani nga update path: existing ra ang target.
    IF NOT EXISTS (SELECT 1 FROM SUPPLIERS WHERE SupplierID = @SupplierID)
        THROW 50388, 'The supplier was not found.', 1;

    IF @CleanName IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM SUPPLIERS
                   WHERE SupplierName = @CleanName AND SupplierID <> @SupplierID)
            THROW 50387, 'A supplier with this name already exists.', 1;
    END;

    IF @CleanEmail IS NOT NULL AND @CleanEmail NOT LIKE N'%_@_%._%'
        THROW 50386, 'The contact email address is not valid.', 1;

    -- Kani nga COALESCE pattern kay para ang fields nga wala
    -- gihatag (NULL) dili ma-overwrite sa update.
    UPDATE SUPPLIERS
    SET SupplierName = COALESCE(@CleanName, SupplierName),
        ContactPersonFirstName = COALESCE(@CleanFirst, ContactPersonFirstName),
        ContactPersonMiddleName = COALESCE(@CleanMiddle, ContactPersonMiddleName),
        ContactPersonLastName = COALESCE(@CleanLast, ContactPersonLastName),
        Phone = COALESCE(@CleanPhone, Phone),
        Email = COALESCE(@CleanEmail, Email),
        Address = COALESCE(@CleanAddress, Address),
        IsActive = COALESCE(@IsActive, IsActive)
    WHERE SupplierID = @SupplierID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'SUPPLIER_UPDATED',
            CONCAT('Supplier details were updated for SupplierID ', @SupplierID, '.'));
END;
GO
