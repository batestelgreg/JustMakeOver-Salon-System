USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO


IF OBJECT_ID(N'dbo.EMAIL_SETTINGS', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.EMAIL_SETTINGS
    (
        SettingID TINYINT NOT NULL
            CONSTRAINT PK_EMAIL_SETTINGS PRIMARY KEY
            CONSTRAINT DF_EMAIL_SETTINGS_SettingID DEFAULT (1),
        SenderEmail NVARCHAR(255) NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_SenderEmail DEFAULT (N''),
        SenderName NVARCHAR(120) NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_SenderName DEFAULT (N'Just MakeOver Beauty Salon & Spa'),
        EncryptedAppPassword NVARCHAR(MAX) NULL,
        SmtpHost NVARCHAR(150) NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_SmtpHost DEFAULT (N'smtp.gmail.com'),
        SmtpPort INT NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_SmtpPort DEFAULT (587),
        UseStartTls BIT NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_UseStartTls DEFAULT (1),
        UpdatedByUserID INT NULL,
        UpdatedAt DATETIME2(0) NOT NULL
            CONSTRAINT DF_EMAIL_SETTINGS_UpdatedAt DEFAULT (SYSDATETIME()),
        CONSTRAINT CK_EMAIL_SETTINGS_SingleRow CHECK (SettingID = 1),
        CONSTRAINT CK_EMAIL_SETTINGS_Port CHECK (SmtpPort BETWEEN 1 AND 65535)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_EMAIL_SETTINGS_UpdatedBy'
)
    ALTER TABLE dbo.EMAIL_SETTINGS
        ADD CONSTRAINT FK_EMAIL_SETTINGS_UpdatedBy
        FOREIGN KEY (UpdatedByUserID) REFERENCES dbo.USERS (UserID);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.EMAIL_SETTINGS WHERE SettingID = 1)
BEGIN
    DECLARE @DefaultSalonName NVARCHAR(120) = ISNULL(
        NULLIF(LTRIM(RTRIM(
            (SELECT TOP (1) SettingValue FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'SalonName')
        )), N''),
        N'Just MakeOver Beauty Salon & Spa');

    INSERT INTO dbo.EMAIL_SETTINGS
    (
        SettingID,
        SenderEmail,
        SenderName,
        EncryptedAppPassword,
        SmtpHost,
        SmtpPort,
        UseStartTls,
        UpdatedAt
    )
    VALUES
    (
        1,
        N'',
        @DefaultSalonName,
        NULL,
        N'smtp.gmail.com',
        587,
        1,
        SYSDATETIME()
    );
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Settings_GetEmailSettings
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50370, 'You do not have permission to view email settings.', 1;

    SELECT TOP (1)
        es.SenderEmail,
        es.SenderName,
        es.SmtpHost,
        es.SmtpPort,
        es.UseStartTls,
        CAST(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(ISNULL(es.EncryptedAppPassword, N''))), N'') IS NOT NULL
                    THEN 1
                ELSE 0
            END AS BIT
        ) AS HasPassword,
        es.UpdatedAt,
        NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName, N' ', u.LastName))), N'') AS UpdatedByName
    FROM dbo.EMAIL_SETTINGS es
    LEFT JOIN dbo.USERS u ON u.UserID = es.UpdatedByUserID
    WHERE es.SettingID = 1;
END;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Settings_SaveEmailSettings
    @ActorUserID INT,
    @SenderEmail NVARCHAR(255),
    @SenderName NVARCHAR(120),
    @EncryptedAppPassword NVARCHAR(MAX) = NULL,
    @SmtpHost NVARCHAR(150) = N'smtp.gmail.com',
    @SmtpPort INT = 587,
    @UseStartTls BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50371, 'You do not have permission to manage official salon email settings.', 1;

    DECLARE
        @CleanEmail NVARCHAR(255) = LTRIM(RTRIM(ISNULL(@SenderEmail, N''))),
        @CleanName NVARCHAR(120) = LTRIM(RTRIM(ISNULL(@SenderName, N''))),
        @CleanHost NVARCHAR(150) = LTRIM(RTRIM(ISNULL(@SmtpHost, N''))),
        @CleanEncrypted NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(ISNULL(@EncryptedAppPassword, N''))), N''),
        @Now DATETIME2(0) = SYSDATETIME();

    IF @CleanEmail = N''
        THROW 50372, 'Official salon email address is required.', 1;

    IF @CleanEmail NOT LIKE N'%_@_%._%'
       OR CHARINDEX(N' ', @CleanEmail) > 0
       OR CHARINDEX(N'@', @CleanEmail, CHARINDEX(N'@', @CleanEmail) + 1) > 0
        THROW 50373, 'Please enter a valid official salon email address.', 1;

    IF @CleanName = N''
        THROW 50374, 'Sender display name is required.', 1;

    IF @CleanHost = N''
        THROW 50375, 'SMTP host is required.', 1;

    IF @SmtpPort IS NULL OR @SmtpPort < 1 OR @SmtpPort > 65535
        THROW 50376, 'SMTP port must be between 1 and 65535.', 1;

    DECLARE @HasExistingPassword BIT =
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM dbo.EMAIL_SETTINGS
                WHERE SettingID = 1
                  AND NULLIF(LTRIM(RTRIM(ISNULL(EncryptedAppPassword, N''))), N'') IS NOT NULL
            ) THEN 1
            ELSE 0
        END;

    IF @CleanEncrypted IS NULL AND @HasExistingPassword = 0
        THROW 50377, 'Please enter the 16-character Google App Password for the official salon email.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM dbo.EMAIL_SETTINGS WHERE SettingID = 1)
        BEGIN
            UPDATE dbo.EMAIL_SETTINGS
            SET SenderEmail = @CleanEmail,
                SenderName = @CleanName,
                EncryptedAppPassword = COALESCE(@CleanEncrypted, EncryptedAppPassword),
                SmtpHost = @CleanHost,
                SmtpPort = @SmtpPort,
                UseStartTls = ISNULL(@UseStartTls, 1),
                UpdatedByUserID = @ActorUserID,
                UpdatedAt = @Now
            WHERE SettingID = 1;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.EMAIL_SETTINGS
            (
                SettingID,
                SenderEmail,
                SenderName,
                EncryptedAppPassword,
                SmtpHost,
                SmtpPort,
                UseStartTls,
                UpdatedByUserID,
                UpdatedAt
            )
            VALUES
            (
                1,
                @CleanEmail,
                @CleanName,
                @CleanEncrypted,
                @CleanHost,
                @SmtpPort,
                ISNULL(@UseStartTls, 1),
                @ActorUserID,
                @Now
            );
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
            'EMAIL_SETTINGS_UPDATED',
            LEFT(
                CONCAT(
                    N'Updated Official Salon Email (SMTP) configuration to ',
                    @CleanEmail,
                    N' (',
                    @CleanHost,
                    N':',
                    @SmtpPort,
                    N').'
                ),
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

    EXEC dbo.usp_Settings_GetEmailSettings @ActorUserID = @ActorUserID;
END;
GO



CREATE OR ALTER PROCEDURE dbo.usp_Email_GetRuntimeConfig
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

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
              p.PermissionCode IN ('purchasing.manage', 'requisitions.approve', 'settings.manage')
              OR r.RoleName IN (N'Admin', N'Manager')
          )
    )
        THROW 50378, 'You do not have permission to access salon email dispatch configuration.', 1;

    SELECT TOP (1)
        es.SenderEmail,
        es.SenderName,
        es.EncryptedAppPassword,
        es.SmtpHost,
        es.SmtpPort,
        es.UseStartTls
    FROM dbo.EMAIL_SETTINGS es
    WHERE es.SettingID = 1;
END;
GO
