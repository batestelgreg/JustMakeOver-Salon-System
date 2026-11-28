-- =============================================================================
-- JustMakeOverSalonDB Consolidated Clean-Starter Setup Script
-- Generated from live JustMakeOverSalonDB (Schema + Clean Starter Seed Data)
-- =============================================================================
IF DB_ID(N'JustMakeOverSalonDB') IS NULL
BEGIN
    CREATE DATABASE [JustMakeOverSalonDB];
END;
GO

USE [JustMakeOverSalonDB];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. SEQUENCES
CREATE SEQUENCE [dbo].[PurchasingDeliveryReferenceSequence] AS [bigint] START WITH 1 INCREMENT BY 1 MINVALUE -9223372036854775808 MAXVALUE 9223372036854775807 NO CYCLE;
GO

-- 2. FUNCTIONS
/* ============================================================
   2. ACKNOWLEDGEMENT ACCESS BASED ON RECEIPT OWNERSHIP

   Any active receipt owner can acknowledge their own receipt.
   Admin retains access to all receipts.

   V028 procedures and GetOverview already call this function.
   ============================================================ */

CREATE   FUNCTION dbo.fn_DeliveryCanAcknowledge
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
   4. DELIVERY MANAGEMENT â€” RESPECT DYNAMIC delivery.manage PERMISSION
   ============================================================ */

CREATE   FUNCTION dbo.fn_DeliveryCanManage
(
    @ActorUserID INT
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
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
    )
        SET @Allowed = 1;

    RETURN @Allowed;
END;
GO

/* 
   3. DOCUMENT SNAPSHOT HASH
   Kani nga hash kay naka-bind sa immutable business terms sa matag
   document aron ang normal nga status transitions (pananglitan PO
   Approved -> Sent -> Delivered) dili makahimo og false tamper alert,
   pero ang bisan unsang pag-usab sa gidaghanon, presyo, item, o notes
   kay masakpan dayon.
  */

CREATE   FUNCTION dbo.fn_DocumentSignatureHash
(
    @DocumentType VARCHAR(40),
    @DocumentID INT
)
RETURNS CHAR(64)
AS
BEGIN
    DECLARE @canonical NVARCHAR(2000);

    IF @DocumentType = 'PURCHASE_ORDER'
    BEGIN
        SELECT @canonical = CONCAT(
            'PO|', po.POID, '|', po.PRID, '|', po.SupplierID, '|',
            po.QuantityOrdered, '|',
            CONVERT(VARCHAR(40), po.UnitPrice, 2), '|',
            CONVERT(VARCHAR(40), po.TotalAmount, 2), '|',
            ISNULL(CONVERT(VARCHAR(30), po.ApprovedByUserID), '')
        )
        FROM dbo.PURCHASE_ORDERS po
        WHERE po.POID = @DocumentID;
    END
    ELSE IF @DocumentType = 'RECEIVING_REPORT'
    BEGIN
        SELECT @canonical = CONCAT(
            'RR|', l.InventoryLogID, '|', l.ItemID, '|',
            l.TransactionType, '|', l.QuantityChange, '|',
            l.PreviousQuantity, '|', l.NewQuantity, '|',
            ISNULL(l.ReferenceType, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), l.ReferenceID), ''), '|',
            CONVERT(VARCHAR(30), l.TransactionDate, 126)
        )
        FROM dbo.INVENTORY_LOGS l
        WHERE l.InventoryLogID = @DocumentID;
    END
    ELSE IF @DocumentType = 'STOCK_CARD'
    BEGIN
        SELECT @canonical = CONCAT(
            'SC|', i.ItemID, '|', i.ItemCode, '|',
            ISNULL(CONVERT(VARCHAR(30), inv.QuantityOnHand), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), inv.QuantityReserved), '0'), '|',
            ISNULL(
                CONVERT(VARCHAR(30),
                    (SELECT MAX(x.InventoryLogID)
                     FROM dbo.INVENTORY_LOGS x
                     WHERE x.ItemID = i.ItemID)),
                '0')
        )
        FROM dbo.ITEMS i
        LEFT JOIN dbo.INVENTORY inv
            ON inv.ItemID = i.ItemID
        WHERE i.ItemID = @DocumentID;
    END
    ELSE IF @DocumentType = 'CORRECTION_REPORT'
    BEGIN
        SELECT @canonical = CONCAT(
            'CR|', d.DeliveryID, '|',
            ISNULL(d.CorrectionNotes, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), d.CorrectedAt, 126), ''), '|',
            ISNULL(CONVERT(VARCHAR(30), d.CorrectedByUserID), '')
        )
        FROM dbo.DELIVERIES d
        WHERE d.DeliveryID = @DocumentID;
    END
    ELSE IF @DocumentType = 'REQUISITION'
    BEGIN
        SELECT @canonical = CONCAT(
            'RF|', r.RequisitionID, '|', r.RequestorUserID, '|',
            CONVERT(VARCHAR(10), r.RequiredDate, 23), '|',
            ISNULL(r.Justification, ''), '|',
            ISNULL(CONVERT(VARCHAR(30), r.DepartmentHeadUserID), '')
        )
        FROM dbo.REQUISITIONS r
        WHERE r.RequisitionID = @DocumentID;
    END
    ELSE IF @DocumentType = 'REPLENISHMENT_REQUEST'
    BEGIN
        SELECT @canonical = CONCAT(
            'REPF|', rr.RepFID, '|', rr.ItemID, '|',
            rr.QuantityNeeded, '|',
            ISNULL(CONVERT(VARCHAR(30), rr.OriginRequisitionID), '')
        )
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.RepFID = @DocumentID;
    END
    ELSE IF @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT'
    BEGIN
        SELECT @canonical = CONCAT(
            'AR|', d.DeliveryID, '|', d.ARCode, '|',
            d.RequisitionID, '|', d.RequestorUserID, '|',
            CONVERT(VARCHAR(30), d.GeneratedDate, 126)
        )
        FROM dbo.DELIVERIES d
        WHERE d.DeliveryID = @DocumentID;
    END
    ELSE IF @DocumentType = 'DELIVERY_CHECK'
    BEGIN
        SELECT @canonical = CONCAT(
            'DR|', dr.DRID, '|', dr.POID, '|',
            CONVERT(VARCHAR(30), dr.DeliveryDate, 126), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityDelivered), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityAccepted), '0'), '|',
            ISNULL(CONVERT(VARCHAR(30), dd.QuantityRejected), '0')
        )
        FROM dbo.DELIVERY_RECEIPTS dr
        LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS dd
            ON dd.DRID = dr.DRID
        WHERE dr.DRID = @DocumentID;
    END;

    RETURN CONVERT(
        CHAR(64),
        HASHBYTES('SHA2_256', ISNULL(@canonical, N'')),
        2);
END;
GO

-- 3. TABLES, CONSTRAINTS & INDEXES
CREATE TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] (
    [ARDetailID] [int] IDENTITY(1,1) NOT NULL,
    [ARID] [int] NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityIssued] [int] NOT NULL,
    CONSTRAINT [PK_AR_DETAILS] PRIMARY KEY CLUSTERED ([ARDetailID] ASC),
    CONSTRAINT [UQ_ARDETAILS_AR_Item] UNIQUE NONCLUSTERED ([ARID] ASC, [ItemID] ASC),
    CONSTRAINT [CK_ARDETAILS_Quantity] CHECK ([QuantityIssued]>(0))
);
GO

CREATE TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] (
    [ARID] [int] IDENTITY(1,1) NOT NULL,
    [RequisitionID] [int] NOT NULL,
    [IssuedByUserID] [int] NOT NULL,
    [ReceivedByUserID] [int] NOT NULL,
    [IssueDate] [datetime2](0) NOT NULL CONSTRAINT [DF_AR_IssueDate] DEFAULT (sysdatetime()),
    [ESignatureData] [nvarchar](MAX) NOT NULL,
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_AR_Status] DEFAULT ('Fulfilled'),
    CONSTRAINT [PK_ACKNOWLEDGEMENT_RECEIPTS] PRIMARY KEY CLUSTERED ([ARID] ASC),
    CONSTRAINT [CK_AR_Status] CHECK ([Status]='Cancelled' OR [Status]='With Discrepancies' OR [Status]='Fulfilled' OR [Status]='Pending')
);
GO

CREATE TABLE [dbo].[CATEGORIES] (
    [CategoryID] [int] IDENTITY(1,1) NOT NULL,
    [CategoryName] [nvarchar](50) NOT NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF__CATEGORIE__IsAct__52E34C9D] DEFAULT ((1)),
    CONSTRAINT [PK_CATEGORIES] PRIMARY KEY CLUSTERED ([CategoryID] ASC),
    CONSTRAINT [UQ_CATEGORIES_CategoryName] UNIQUE NONCLUSTERED ([CategoryName] ASC)
);
GO

CREATE TABLE [dbo].[DELIVERIES] (
    [DeliveryID] [int] IDENTITY(1,1) NOT NULL,
    [ARCode] [varchar](30) NOT NULL,
    [RequisitionID] [int] NOT NULL,
    [RequestorUserID] [int] NOT NULL,
    [GeneratedByUserID] [int] NOT NULL,
    [GeneratedDate] [datetime2](7) NOT NULL CONSTRAINT [DF_DELIVERIES_Generated] DEFAULT (sysdatetime()),
    [IssuedDate] [datetime2](7) NULL,
    [DiscrepancyNotes] [nvarchar](1000) NULL,
    [SignedByUserID] [int] NULL,
    [SignedDate] [datetime2](7) NULL,
    [Status] [varchar](30) NOT NULL,
    [ESignatureData] [nvarchar](MAX) NULL,
    [DiscrepancyResolvedAt] [datetime] NULL,
    [CorrectedAt] [datetime] NULL,
    [CorrectedByUserID] [int] NULL,
    [CorrectionNotes] [nvarchar](500) NULL,
    [IssuedByUserID] [int] NULL,
    [IssuedSignatureData] [nvarchar](MAX) NULL,
    CONSTRAINT [PK_DELIVERIES] PRIMARY KEY CLUSTERED ([DeliveryID] ASC),
    CONSTRAINT [UQ_DELIVERIES_ARCode] UNIQUE NONCLUSTERED ([ARCode] ASC),
    CONSTRAINT [CK_DELIVERIES_Status] CHECK ([Status]=N'Completed' OR [Status]=N'Issued' OR [Status]=N'Generated')
);
GO
CREATE NONCLUSTERED INDEX [IX_DELIVERIES_Requisition_Status] ON [dbo].[DELIVERIES] ([RequisitionID] ASC, [Status] ASC);
GO

CREATE TABLE [dbo].[DELIVERY_ITEMS] (
    [DeliveryItemID] [int] IDENTITY(1,1) NOT NULL,
    [DeliveryID] [int] NOT NULL,
    [RequisitionDetailID] [int] NOT NULL,
    [ItemID] [int] NOT NULL,
    [Quantity] [int] NOT NULL,
    CONSTRAINT [PK_DELIVERY_ITEMS] PRIMARY KEY CLUSTERED ([DeliveryItemID] ASC),
    CONSTRAINT [CK_DELIVERY_ITEMS_Qty] CHECK ([Quantity]>(0))
);
GO
CREATE NONCLUSTERED INDEX [IX_DELIVERY_ITEMS_Delivery] ON [dbo].[DELIVERY_ITEMS] ([DeliveryID] ASC);
GO

CREATE TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] (
    [DRDetailID] [int] IDENTITY(1,1) NOT NULL,
    [DRID] [int] NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityDelivered] [int] NOT NULL,
    [QuantityAccepted] [int] NOT NULL CONSTRAINT [DF_DRDETAILS_Accepted] DEFAULT ((0)),
    [QuantityRejected] [int] NOT NULL CONSTRAINT [DF_DRDETAILS_Rejected] DEFAULT ((0)),
    [Remarks] [nvarchar](500) NULL,
    CONSTRAINT [PK_DELIVERY_RECEIPT_DETAILS] PRIMARY KEY CLUSTERED ([DRDetailID] ASC),
    CONSTRAINT [UQ_DRDETAILS_DR_Item] UNIQUE NONCLUSTERED ([DRID] ASC, [ItemID] ASC),
    CONSTRAINT [CK_DRDETAILS_Quantities] CHECK ([QuantityDelivered]>(0) AND [QuantityAccepted]>=(0) AND [QuantityRejected]>=(0) AND ([QuantityAccepted]+[QuantityRejected])<=[QuantityDelivered])
);
GO
CREATE NONCLUSTERED INDEX [IX_DRDETAILS_ItemID] ON [dbo].[DELIVERY_RECEIPT_DETAILS] ([ItemID] ASC);
GO

CREATE TABLE [dbo].[DELIVERY_RECEIPTS] (
    [DRID] [int] IDENTITY(1,1) NOT NULL,
    [POID] [int] NOT NULL,
    [DeliveryDate] [datetime2](0) NOT NULL CONSTRAINT [DF_DR_DeliveryDate] DEFAULT (sysdatetime()),
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_DR_Status] DEFAULT ('Accepted'),
    [Notes] [nvarchar](MAX) NULL,
    CONSTRAINT [PK_DELIVERY_RECEIPTS] PRIMARY KEY CLUSTERED ([DRID] ASC),
    CONSTRAINT [CK_DR_Status] CHECK ([Status]='Rejected' OR [Status]='With Discrepancies' OR [Status]='Accepted')
);
GO

CREATE TABLE [dbo].[DELIVERY_SIGNATURE_HISTORY] (
    [SignatureHistoryID] [int] IDENTITY(1,1) NOT NULL,
    [DeliveryID] [int] NOT NULL,
    [Stage] [varchar](20) NOT NULL,
    [UserID] [int] NOT NULL,
    [SignatureData] [nvarchar](MAX) NOT NULL,
    [SignedAt] [datetime2](7) NOT NULL CONSTRAINT [DF_DSH_SignedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_DELIVERY_SIGNATURE_HISTORY] PRIMARY KEY CLUSTERED ([SignatureHistoryID] ASC),
    CONSTRAINT [CK_DSH_Stage] CHECK ([Stage]='Received' OR [Stage]='Issued')
);
GO
CREATE NONCLUSTERED INDEX [IX_DSH_Delivery] ON [dbo].[DELIVERY_SIGNATURE_HISTORY] ([DeliveryID] ASC, [SignatureHistoryID] ASC);
GO

CREATE TABLE [dbo].[DOCUMENT_SIGNATURE_STAGES] (
    [StageID] [int] IDENTITY(1,1) NOT NULL,
    [DocumentType] [varchar](40) NOT NULL,
    [Stage] [varchar](40) NOT NULL,
    [StageLabel] [nvarchar](80) NOT NULL,
    [RoleLabel] [nvarchar](80) NOT NULL,
    [PermissionCodes] [varchar](200) NOT NULL,
    [SortOrder] [int] NOT NULL CONSTRAINT [DF_DSS_SortOrder] DEFAULT ((0)),
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_DSS_IsActive] DEFAULT ((1)),
    CONSTRAINT [PK_DOCUMENT_SIGNATURE_STAGES] PRIMARY KEY CLUSTERED ([StageID] ASC)
);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UQ_DOCUMENT_SIGNATURE_STAGES] ON [dbo].[DOCUMENT_SIGNATURE_STAGES] ([DocumentType] ASC, [Stage] ASC);
GO

CREATE TABLE [dbo].[DOCUMENT_SIGNATURES] (
    [SignatureID] [bigint] IDENTITY(1,1) NOT NULL,
    [DocumentType] [varchar](40) NOT NULL,
    [DocumentID] [int] NOT NULL,
    [Stage] [varchar](40) NOT NULL,
    [SignerUserID] [int] NOT NULL,
    [SignerName] [nvarchar](200) NOT NULL,
    [SignerRole] [nvarchar](100) NOT NULL,
    [SignatureImage] [nvarchar](MAX) NOT NULL,
    [DocumentHash] [char](64) NOT NULL,
    [SignedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_DOCUMENT_SIGNATURES_SignedAt] DEFAULT (sysdatetime()),
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_DOCUMENT_SIGNATURES_IsActive] DEFAULT ((1)),
    [RevokedAt] [datetime2](0) NULL,
    [RevokedByUserID] [int] NULL,
    [RevokeReason] [nvarchar](500) NULL,
    [ConfirmationAccepted] [bit] NOT NULL CONSTRAINT [DF_DOCUMENT_SIGNATURES_Confirmed] DEFAULT ((1)),
    CONSTRAINT [PK_DOCUMENT_SIGNATURES] PRIMARY KEY CLUSTERED ([SignatureID] ASC)
);
GO
CREATE NONCLUSTERED INDEX [IX_DOCUMENT_SIGNATURES_Document] ON [dbo].[DOCUMENT_SIGNATURES] ([DocumentType] ASC, [DocumentID] ASC);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_DOCUMENT_SIGNATURES_Active] ON [dbo].[DOCUMENT_SIGNATURES] ([DocumentType] ASC, [DocumentID] ASC, [Stage] ASC) WHERE ([IsActive]=(1));
GO

CREATE TABLE [dbo].[EMAIL_LOGS] (
    [EmailLogID] [bigint] IDENTITY(1,1) NOT NULL,
    [POID] [int] NOT NULL,
    [EmailType] [varchar](30) NOT NULL CONSTRAINT [DF_EMAIL_LOGS_EmailType] DEFAULT ('PURCHASE_ORDER'),
    [FollowupID] [int] NULL,
    [RecipientEmail] [nvarchar](255) NOT NULL,
    [Subject] [nvarchar](300) NOT NULL,
    [EmailStatus] [varchar](20) NOT NULL CONSTRAINT [DF_EMAIL_LOGS_EmailStatus] DEFAULT ('Pending'),
    [SentAt] [datetime2](0) NULL,
    [ErrorMessage] [nvarchar](1000) NULL,
    [TriggeredByUserID] [int] NOT NULL,
    [CreatedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_EMAIL_LOGS_CreatedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_EMAIL_LOGS] PRIMARY KEY CLUSTERED ([EmailLogID] ASC),
    CONSTRAINT [CK_EMAIL_LOGS_Status] CHECK ([EmailStatus]='Failed' OR [EmailStatus]='Sent' OR [EmailStatus]='Pending')
);
GO
CREATE NONCLUSTERED INDEX [IX_EMAIL_LOGS_POID_CreatedAt] ON [dbo].[EMAIL_LOGS] ([POID] ASC, [EmailType] ASC, [CreatedAt] DESC, [EmailLogID] DESC);
GO

CREATE TABLE [dbo].[EMAIL_SETTINGS] (
    [SettingID] [tinyint] NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_SettingID] DEFAULT ((1)),
    [SenderEmail] [nvarchar](255) NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_SenderEmail] DEFAULT (N''),
    [SenderName] [nvarchar](120) NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_SenderName] DEFAULT (N'Just MakeOver Beauty Salon & Spa'),
    [EncryptedAppPassword] [nvarchar](MAX) NULL,
    [SmtpHost] [nvarchar](150) NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_SmtpHost] DEFAULT (N'smtp.gmail.com'),
    [SmtpPort] [int] NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_SmtpPort] DEFAULT ((587)),
    [UseStartTls] [bit] NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_UseStartTls] DEFAULT ((1)),
    [UpdatedByUserID] [int] NULL,
    [UpdatedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_EMAIL_SETTINGS_UpdatedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_EMAIL_SETTINGS] PRIMARY KEY CLUSTERED ([SettingID] ASC),
    CONSTRAINT [CK_EMAIL_SETTINGS_Port] CHECK ([SmtpPort]>=(1) AND [SmtpPort]<=(65535)),
    CONSTRAINT [CK_EMAIL_SETTINGS_SingleRow] CHECK ([SettingID]=(1))
);
GO

CREATE TABLE [dbo].[INVENTORY] (
    [InventoryID] [int] IDENTITY(1,1) NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityOnHand] [int] NOT NULL CONSTRAINT [DF_INVENTORY_QuantityOnHand] DEFAULT ((0)),
    [QuantityReserved] [int] NOT NULL CONSTRAINT [DF_INVENTORY_QuantityReserved] DEFAULT ((0)),
    [QuantityAvailable] AS ([QuantityOnHand]-[QuantityReserved]) PERSISTED,
    [LastUpdated] [datetime2](0) NOT NULL CONSTRAINT [DF_INVENTORY_LastUpdated] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_INVENTORY] PRIMARY KEY CLUSTERED ([InventoryID] ASC),
    CONSTRAINT [UQ_INVENTORY_ItemID] UNIQUE NONCLUSTERED ([ItemID] ASC),
    CONSTRAINT [CK_INVENTORY_Quantities] CHECK ([QuantityOnHand]>=(0) AND [QuantityReserved]>=(0) AND [QuantityReserved]<=[QuantityOnHand])
);
GO

CREATE TABLE [dbo].[INVENTORY_LOGS] (
    [InventoryLogID] [bigint] IDENTITY(1,1) NOT NULL,
    [ItemID] [int] NOT NULL,
    [UserID] [int] NOT NULL,
    [TransactionType] [varchar](30) NOT NULL,
    [QuantityChange] [int] NOT NULL,
    [PreviousQuantity] [int] NOT NULL,
    [NewQuantity] [int] NOT NULL,
    [ReferenceType] [varchar](30) NULL,
    [ReferenceID] [int] NULL,
    [Remarks] [nvarchar](500) NULL,
    [TransactionDate] [datetime2](0) NOT NULL CONSTRAINT [DF_INVENTORY_LOGS_Date] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_INVENTORY_LOGS] PRIMARY KEY CLUSTERED ([InventoryLogID] ASC),
    CONSTRAINT [CK_INVENTORY_LOGS_Quantities] CHECK ([PreviousQuantity]>=(0) AND [NewQuantity]>=(0)),
    CONSTRAINT [CK_INVENTORY_LOGS_QuantityCalculation] CHECK ([NewQuantity]=([PreviousQuantity]+[QuantityChange])),
    CONSTRAINT [CK_INVENTORY_LOGS_Type] CHECK ([TransactionType]='Adjustment' OR [TransactionType]='Release' OR [TransactionType]='Reservation' OR [TransactionType]='Stock Out' OR [TransactionType]='Stock In')
);
GO
CREATE NONCLUSTERED INDEX [IX_INVENTORY_LOGS_Date] ON [dbo].[INVENTORY_LOGS] ([TransactionDate] DESC, [ItemID] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_INVENTORY_LOGS_ItemID_TransactionDate] ON [dbo].[INVENTORY_LOGS] ([ItemID] ASC, [TransactionDate] DESC);
GO

CREATE TABLE [dbo].[INVENTORY_RESERVATIONS] (
    [ReservationID] [int] IDENTITY(1,1) NOT NULL,
    [RequisitionDetailID] [int] NOT NULL,
    [QuantityReserved] [int] NOT NULL,
    [ReservationDate] [datetime2](0) NOT NULL CONSTRAINT [DF_RESERVATIONS_Date] DEFAULT (sysdatetime()),
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_RESERVATIONS_Status] DEFAULT ('Active'),
    CONSTRAINT [PK_INVENTORY_RESERVATIONS] PRIMARY KEY CLUSTERED ([ReservationID] ASC),
    CONSTRAINT [CK_RESERVATIONS_Quantity] CHECK ([QuantityReserved]>(0)),
    CONSTRAINT [CK_RESERVATIONS_Status] CHECK ([Status]='Released' OR [Status]='Cancelled' OR [Status]='Fulfilled' OR [Status]='Active')
);
GO
CREATE NONCLUSTERED INDEX [IX_RESERVATIONS_Detail] ON [dbo].[INVENTORY_RESERVATIONS] ([RequisitionDetailID] ASC, [Status] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_RESERVATIONS_RequisitionDetailID_Status] ON [dbo].[INVENTORY_RESERVATIONS] ([RequisitionDetailID] ASC, [Status] ASC);
GO

CREATE TABLE [dbo].[ITEMS] (
    [ItemID] [int] IDENTITY(1,1) NOT NULL,
    [ItemCode] [varchar](30) NOT NULL,
    [ItemName] [nvarchar](100) NOT NULL,
    [CategoryID] [int] NOT NULL,
    [UnitOfMeasure] [nvarchar](20) NOT NULL,
    [ReorderPoint] [int] NOT NULL CONSTRAINT [DF_ITEMS_ReorderPoint] DEFAULT ((10)),
    [UnitPrice] [decimal](10,2) NOT NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_ITEMS_IsActive] DEFAULT ((1)),
    CONSTRAINT [PK_ITEMS] PRIMARY KEY CLUSTERED ([ItemID] ASC),
    CONSTRAINT [UQ_ITEMS_ItemCode] UNIQUE NONCLUSTERED ([ItemCode] ASC),
    CONSTRAINT [CK_ITEMS_ReorderPoint] CHECK ([ReorderPoint]>=(0)),
    CONSTRAINT [CK_ITEMS_UnitPrice] CHECK ([UnitPrice]>=(0))
);
GO

CREATE TABLE [dbo].[NOTIFICATIONS] (
    [NotificationID] [bigint] IDENTITY(1,1) NOT NULL,
    [RecipientUserID] [int] NOT NULL,
    [NotificationType] [varchar](50) NOT NULL,
    [Title] [nvarchar](150) NOT NULL,
    [Message] [nvarchar](1000) NOT NULL,
    [RelatedEntityType] [varchar](50) NULL,
    [RelatedEntityID] [int] NULL,
    [IsRead] [bit] NOT NULL CONSTRAINT [DF_NOTIFICATIONS_IsRead] DEFAULT ((0)),
    [CreatedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_NOTIFICATIONS_CreatedAt] DEFAULT (sysdatetime()),
    [ReadAt] [datetime2](0) NULL,
    CONSTRAINT [PK_NOTIFICATIONS] PRIMARY KEY CLUSTERED ([NotificationID] ASC),
    CONSTRAINT [CK_NOTIFICATIONS_ReadState] CHECK ([IsRead]=(0) AND [ReadAt] IS NULL OR [IsRead]=(1) AND [ReadAt] IS NOT NULL)
);
GO
CREATE NONCLUSTERED INDEX [IX_NOTIFICATIONS_Recipient] ON [dbo].[NOTIFICATIONS] ([RecipientUserID] ASC, [IsRead] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_NOTIFICATIONS_Recipient_Read_Created] ON [dbo].[NOTIFICATIONS] ([RecipientUserID] ASC, [IsRead] ASC, [CreatedAt] DESC);
GO

CREATE TABLE [dbo].[PERMISSIONS] (
    [PermissionID] [int] IDENTITY(1,1) NOT NULL,
    [PermissionCode] [varchar](100) NOT NULL,
    [Description] [nvarchar](255) NULL,
    CONSTRAINT [PK_PERMISSIONS] PRIMARY KEY CLUSTERED ([PermissionID] ASC),
    CONSTRAINT [UQ_PERMISSIONS_Code] UNIQUE NONCLUSTERED ([PermissionCode] ASC)
);
GO

CREATE TABLE [dbo].[PO_PR_Mapping] (
    [POID] [int] NOT NULL,
    [PRID] [int] NOT NULL,
    CONSTRAINT [PK_PO_PR_Mapping] PRIMARY KEY CLUSTERED ([POID] ASC, [PRID] ASC)
);
GO
CREATE NONCLUSTERED INDEX [IX_PO_PR_Mapping_PRID] ON [dbo].[PO_PR_Mapping] ([PRID] ASC);
GO

CREATE TABLE [dbo].[PURCHASE_BUDGETS] (
    [BudgetID] [int] IDENTITY(1,1) NOT NULL,
    [BudgetYear] [int] NOT NULL,
    [BudgetAmount] [decimal](14,2) NOT NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_PURCHASE_BUDGETS_IsActive] DEFAULT ((1)),
    [CreatedByUserID] [int] NOT NULL,
    [CreatedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_PURCHASE_BUDGETS_CreatedAt] DEFAULT (sysdatetime()),
    [UpdatedAt] [datetime2](0) NULL,
    CONSTRAINT [PK_PURCHASE_BUDGETS] PRIMARY KEY CLUSTERED ([BudgetID] ASC),
    CONSTRAINT [UQ_PURCHASE_BUDGETS_Year] UNIQUE NONCLUSTERED ([BudgetYear] ASC),
    CONSTRAINT [CK_PURCHASE_BUDGETS_Amount] CHECK ([BudgetAmount]>=(0)),
    CONSTRAINT [CK_PURCHASE_BUDGETS_Year] CHECK ([BudgetYear]>=(2000) AND [BudgetYear]<=(2100))
);
GO
CREATE NONCLUSTERED INDEX [IX_PURCHASE_BUDGETS_ActiveYear] ON [dbo].[PURCHASE_BUDGETS] ([BudgetYear] ASC, [IsActive] ASC);
GO

CREATE TABLE [dbo].[PURCHASE_ORDERS] (
    [POID] [int] IDENTITY(1,1) NOT NULL,
    [PRID] [int] NOT NULL,
    [SupplierID] [int] NOT NULL,
    [ApprovedByUserID] [int] NULL,
    [QuantityOrdered] [int] NOT NULL,
    [UnitPrice] [decimal](10,2) NOT NULL,
    [TotalAmount] [decimal](12,2) NOT NULL,
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_PO_Status] DEFAULT ('Pending Approval'),
    [DateIssued] [datetime2](0) NOT NULL CONSTRAINT [DF_PO_DateIssued] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_PURCHASE_ORDERS] PRIMARY KEY CLUSTERED ([POID] ASC),
    CONSTRAINT [CK_PO_QuantitiesAndPrices] CHECK ([QuantityOrdered]>(0) AND [UnitPrice]>=(0) AND [TotalAmount]>=(0) AND [TotalAmount]=[QuantityOrdered]*[UnitPrice]),
    CONSTRAINT [CK_PO_Status] CHECK ([Status]='Cancelled' OR [Status]='Delivered' OR [Status]='Partially Delivered' OR [Status]='Sent to Supplier' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending Approval')
);
GO
CREATE NONCLUSTERED INDEX [IX_PO_Status] ON [dbo].[PURCHASE_ORDERS] ([Status] ASC);
GO

CREATE TABLE [dbo].[PURCHASE_REQUESTS] (
    [PRID] [int] IDENTITY(1,1) NOT NULL,
    [RepFID] [int] NOT NULL,
    [CreatedByUserID] [int] NOT NULL,
    [DateCreated] [datetime2](0) NOT NULL CONSTRAINT [DF_PURCHASE_REQUESTS_DateCreated] DEFAULT (sysdatetime()),
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_PURCHASE_REQUESTS_Status] DEFAULT ('Open'),
    CONSTRAINT [PK_PURCHASE_REQUESTS] PRIMARY KEY CLUSTERED ([PRID] ASC),
    CONSTRAINT [UQ_PURCHASE_REQUESTS_RepFID] UNIQUE NONCLUSTERED ([RepFID] ASC),
    CONSTRAINT [CK_PURCHASE_REQUESTS_Status] CHECK ([Status]='Closed' OR [Status]='Cancelled' OR [Status]='Processed' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending Approval' OR [Status]='Open')
);
GO
CREATE NONCLUSTERED INDEX [IX_PURCHASE_REQUESTS_Status] ON [dbo].[PURCHASE_REQUESTS] ([Status] ASC);
GO

CREATE TABLE [dbo].[PURCHASING_DR_TRACKING] (
    [DRID] [int] NOT NULL,
    [POID] [int] NOT NULL,
    [SupplierDRNumber] [nvarchar](100) NOT NULL,
    [RecordedByUserID] [int] NOT NULL,
    [ReplacementRequestedAt] [datetime2](7) NULL,
    CONSTRAINT [PK_PURCHASING_DR_TRACKING] PRIMARY KEY CLUSTERED ([DRID] ASC),
    CONSTRAINT [UQ_PURCHASING_SUPPLIER_DR] UNIQUE NONCLUSTERED ([POID] ASC, [SupplierDRNumber] ASC)
);
GO

CREATE TABLE [dbo].[PURCHASING_FOLLOWUPS] (
    [FollowupID] [int] IDENTITY(1,1) NOT NULL,
    [POID] [int] NOT NULL,
    [ReminderDate] [date] NOT NULL,
    [Message] [nvarchar](2000) NOT NULL,
    [SentAt] [datetime2](7) NULL,
    [SentByUserID] [int] NULL,
    CONSTRAINT [PK_PURCHASING_FOLLOWUPS] PRIMARY KEY CLUSTERED ([FollowupID] ASC),
    CONSTRAINT [UQ_PURCHASING_FOLLOWUP_DAY] UNIQUE NONCLUSTERED ([POID] ASC, [ReminderDate] ASC)
);
GO

CREATE TABLE [dbo].[PURCHASING_PO_TRACKING] (
    [POID] [int] NOT NULL,
    [ExpectedDate] [date] NULL,
    [DispatchedAt] [datetime2](7) NULL,
    [DecisionReason] [nvarchar](1000) NULL,
    [ReceivedBeforeOrder] [int] NOT NULL CONSTRAINT [DF_PURCHASING_PO_ReceivedBefore] DEFAULT ((0)),
    CONSTRAINT [PK_PURCHASING_PO_TRACKING] PRIMARY KEY CLUSTERED ([POID] ASC)
);
GO

CREATE TABLE [dbo].[RECEIVING_MEMO_DETAILS] (
    [RMDetailID] [int] IDENTITY(1,1) NOT NULL,
    [RMID] [int] NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityReceived] [int] NOT NULL,
    CONSTRAINT [PK_RECEIVING_MEMO_DETAILS] PRIMARY KEY CLUSTERED ([RMDetailID] ASC),
    CONSTRAINT [UQ_RMDETAILS_RM_Item] UNIQUE NONCLUSTERED ([RMID] ASC, [ItemID] ASC),
    CONSTRAINT [CK_RMDETAILS_Quantity] CHECK ([QuantityReceived]>(0))
);
GO

CREATE TABLE [dbo].[RECEIVING_MEMOS] (
    [RMID] [int] IDENTITY(1,1) NOT NULL,
    [DRID] [int] NOT NULL,
    [ReceivedByUserID] [int] NOT NULL,
    [DateReceived] [datetime2](0) NOT NULL CONSTRAINT [DF_RM_DateReceived] DEFAULT (sysdatetime()),
    [Remarks] [nvarchar](MAX) NULL,
    [InventoryUpdated] [bit] NOT NULL CONSTRAINT [DF_RM_InventoryUpdated] DEFAULT ((0)),
    CONSTRAINT [PK_RECEIVING_MEMOS] PRIMARY KEY CLUSTERED ([RMID] ASC),
    CONSTRAINT [UQ_RECEIVING_MEMOS_DRID] UNIQUE NONCLUSTERED ([DRID] ASC)
);
GO

CREATE TABLE [dbo].[REPLENISHMENT_REQUESTS] (
    [RepFID] [int] IDENTITY(1,1) NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityNeeded] [int] NOT NULL,
    [DateGenerated] [datetime2](0) NOT NULL CONSTRAINT [DF_REPF_DateGenerated] DEFAULT (sysdatetime()),
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_REPF_Status] DEFAULT ('Pending'),
    [QuantityReceived] [int] NOT NULL CONSTRAINT [DF_REPF_QuantityReceived] DEFAULT ((0)),
    [OriginRequisitionID] [int] NULL,
    CONSTRAINT [PK_REPLENISHMENT_REQUESTS] PRIMARY KEY CLUSTERED ([RepFID] ASC),
    CONSTRAINT [CK_REPF_Quantity] CHECK ([QuantityNeeded]>(0)),
    CONSTRAINT [CK_REPF_Status] CHECK ([Status]='Cancelled' OR [Status]='Processed' OR [Status]='Pending')
);
GO
CREATE NONCLUSTERED INDEX [IX_REPF_Item_Status] ON [dbo].[REPLENISHMENT_REQUESTS] ([ItemID] ASC, [Status] ASC);
GO

CREATE TABLE [dbo].[REPORT_AUDIT_LOGS] (
    [ReportAuditID] [bigint] IDENTITY(1,1) NOT NULL,
    [ActorUserID] [int] NOT NULL,
    [ActorRole] [nvarchar](100) NOT NULL,
    [ReportCode] [varchar](60) NOT NULL,
    [ActionType] [varchar](30) NOT NULL,
    [FilterSummary] [nvarchar](1000) NULL,
    [RowCount] [int] NULL,
    [CreatedAt] [datetime2](0) NOT NULL CONSTRAINT [DF_REPORT_AUDIT_LOGS_CreatedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_REPORT_AUDIT_LOGS] PRIMARY KEY CLUSTERED ([ReportAuditID] ASC)
);
GO
CREATE NONCLUSTERED INDEX [IX_REPORT_AUDIT_LOGS_CodeDate] ON [dbo].[REPORT_AUDIT_LOGS] ([ReportCode] ASC, [CreatedAt] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_REPORT_AUDIT_LOGS_CreatedAt] ON [dbo].[REPORT_AUDIT_LOGS] ([CreatedAt] DESC);
GO

CREATE TABLE [dbo].[REQUISITION_DETAILS] (
    [RequisitionDetailID] [int] IDENTITY(1,1) NOT NULL,
    [RequisitionID] [int] NOT NULL,
    [ItemID] [int] NOT NULL,
    [QuantityRequested] [int] NOT NULL,
    [QuantityApproved] [int] NULL,
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_REQDETAILS_Status] DEFAULT ('Pending'),
    CONSTRAINT [PK_REQUISITION_DETAILS] PRIMARY KEY CLUSTERED ([RequisitionDetailID] ASC),
    CONSTRAINT [CK_REQDETAILS_Quantities] CHECK ([QuantityRequested]>(0) AND ([QuantityApproved] IS NULL OR [QuantityApproved]>=(0) AND [QuantityApproved]<=[QuantityRequested])),
    CONSTRAINT [CK_REQDETAILS_Status] CHECK ([Status]='Fulfilled' OR [Status]='Partially Fulfilled' OR [Status]='Cancelled' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending')
);
GO
CREATE NONCLUSTERED INDEX [IX_REQUISITION_DETAILS_RequisitionID] ON [dbo].[REQUISITION_DETAILS] ([RequisitionID] ASC);
GO

CREATE TABLE [dbo].[REQUISITIONS] (
    [RequisitionID] [int] IDENTITY(1,1) NOT NULL,
    [RequestorUserID] [int] NOT NULL,
    [DepartmentHeadUserID] [int] NULL,
    [RequestDate] [datetime2](0) NOT NULL CONSTRAINT [DF_REQUISITIONS_RequestDate] DEFAULT (sysdatetime()),
    [RequiredDate] [date] NOT NULL,
    [Justification] [nvarchar](500) NULL,
    [Status] [varchar](30) NOT NULL CONSTRAINT [DF_REQUISITIONS_Status] DEFAULT ('Pending'),
    [RejectionReason] [nvarchar](500) NULL,
    [ArchivedAt] [datetime] NULL,
    [ApprovalSignatureData] [nvarchar](MAX) NULL,
    [ApprovedDate] [datetime2](7) NULL,
    CONSTRAINT [PK_REQUISITIONS] PRIMARY KEY CLUSTERED ([RequisitionID] ASC),
    CONSTRAINT [CK_REQUISITIONS_RequiredDate] CHECK ([RequiredDate]>=CONVERT([date],[RequestDate])),
    CONSTRAINT [CK_REQUISITIONS_Status] CHECK ([Status]='Fulfilled' OR [Status]='Cancelled' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending')
);
GO
CREATE NONCLUSTERED INDEX [IX_REQUISITIONS_RequestorUserID] ON [dbo].[REQUISITIONS] ([RequestorUserID] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_REQUISITIONS_Status] ON [dbo].[REQUISITIONS] ([Status] ASC);
GO

CREATE TABLE [dbo].[ROLE_PERMISSIONS] (
    [RoleID] [int] NOT NULL,
    [PermissionID] [int] NOT NULL,
    CONSTRAINT [PK_ROLE_PERMISSIONS] PRIMARY KEY CLUSTERED ([RoleID] ASC, [PermissionID] ASC)
);
GO

CREATE TABLE [dbo].[ROLES] (
    [RoleID] [int] IDENTITY(1,1) NOT NULL,
    [RoleName] [nvarchar](50) NOT NULL,
    [Description] [nvarchar](255) NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_ROLES_IsActive] DEFAULT ((1)),
    CONSTRAINT [PK_ROLES] PRIMARY KEY CLUSTERED ([RoleID] ASC),
    CONSTRAINT [UQ_ROLES_RoleName] UNIQUE NONCLUSTERED ([RoleName] ASC)
);
GO

CREATE TABLE [dbo].[SUPPLIER_QUOTATIONS] (
    [QuotationID] [int] IDENTITY(1,1) NOT NULL,
    [PRID] [int] NOT NULL,
    [SupplierID] [int] NOT NULL,
    [QuotedPrice] [decimal](10,2) NOT NULL,
    [IsRecommended] [bit] NOT NULL CONSTRAINT [DF_QUOTATIONS_IsRecommended] DEFAULT ((0)),
    [DateQuoted] [datetime2](0) NOT NULL CONSTRAINT [DF_QUOTATIONS_DateQuoted] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_SUPPLIER_QUOTATIONS] PRIMARY KEY CLUSTERED ([QuotationID] ASC),
    CONSTRAINT [UQ_QUOTATIONS_PR_Supplier] UNIQUE NONCLUSTERED ([PRID] ASC, [SupplierID] ASC),
    CONSTRAINT [CK_QUOTATIONS_Price] CHECK ([QuotedPrice]>=(0))
);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_QUOTATIONS_OneRecommendedPerPR] ON [dbo].[SUPPLIER_QUOTATIONS] ([PRID] ASC) WHERE ([IsRecommended]=(1));
GO

CREATE TABLE [dbo].[SUPPLIERS] (
    [SupplierID] [int] IDENTITY(1,1) NOT NULL,
    [SupplierCode] [varchar](30) NOT NULL,
    [SupplierName] [nvarchar](100) NOT NULL,
    [ContactPersonLastName] [nvarchar](50) NOT NULL,
    [ContactPersonFirstName] [nvarchar](50) NOT NULL,
    [ContactPersonMiddleName] [nvarchar](50) NULL,
    [Phone] [varchar](20) NOT NULL,
    [Email] [nvarchar](254) NULL,
    [Address] [nvarchar](1000) NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_SUPPLIERS_IsActive] DEFAULT ((1)),
    CONSTRAINT [PK_SUPPLIERS] PRIMARY KEY CLUSTERED ([SupplierID] ASC),
    CONSTRAINT [UQ_SUPPLIERS_Code] UNIQUE NONCLUSTERED ([SupplierCode] ASC)
);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_SUPPLIERS_Email] ON [dbo].[SUPPLIERS] ([Email] ASC) WHERE ([Email] IS NOT NULL);
GO

CREATE TABLE [dbo].[SYSTEM_SETTINGS] (
    [SettingKey] [varchar](50) NOT NULL,
    [SettingValue] [nvarchar](200) NOT NULL,
    [UpdatedAt] [datetime2](7) NOT NULL CONSTRAINT [DF_SYSTEM_SETTINGS_UpdatedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_SYSTEM_SETTINGS] PRIMARY KEY CLUSTERED ([SettingKey] ASC)
);
GO

CREATE TABLE [dbo].[UNIT_OF_MEASURES] (
    [UomID] [int] IDENTITY(1,1) NOT NULL,
    [UomName] [varchar](20) NOT NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_UNIT_OF_MEASURES_IsActive] DEFAULT ((1)),
    [CreatedAt] [datetime2](7) NOT NULL CONSTRAINT [DF_UNIT_OF_MEASURES_CreatedAt] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_UNIT_OF_MEASURES] PRIMARY KEY CLUSTERED ([UomID] ASC),
    CONSTRAINT [UQ_UNIT_OF_MEASURES_Name] UNIQUE NONCLUSTERED ([UomName] ASC)
);
GO

CREATE TABLE [dbo].[USER_AUDIT_LOGS] (
    [AuditID] [bigint] IDENTITY(1,1) NOT NULL,
    [ActorUserID] [int] NULL,
    [TargetUserID] [int] NULL,
    [ActionType] [varchar](50) NOT NULL,
    [Description] [nvarchar](500) NULL,
    [IPAddress] [varchar](45) NULL,
    [ActionDate] [datetime2](0) NOT NULL CONSTRAINT [DF_USER_AUDIT_LOGS_ActionDate] DEFAULT (sysdatetime()),
    CONSTRAINT [PK_USER_AUDIT_LOGS] PRIMARY KEY CLUSTERED ([AuditID] ASC)
);
GO
CREATE NONCLUSTERED INDEX [IX_USER_AUDIT_LOGS_TargetUserID_ActionDate] ON [dbo].[USER_AUDIT_LOGS] ([TargetUserID] ASC, [ActionDate] DESC);
GO

CREATE TABLE [dbo].[USERS] (
    [UserID] [int] IDENTITY(1,1) NOT NULL,
    [LastName] [nvarchar](50) NOT NULL,
    [FirstName] [nvarchar](50) NOT NULL,
    [MiddleName] [nvarchar](50) NULL,
    [Username] [nvarchar](50) NOT NULL,
    [PasswordHash] [varchar](255) NOT NULL,
    [Email] [nvarchar](254) NOT NULL,
    [RoleID] [int] NOT NULL,
    [IsActive] [bit] NOT NULL CONSTRAINT [DF_USERS_IsActive] DEFAULT ((1)),
    [FailedLoginAttempts] [int] NOT NULL CONSTRAINT [DF_USERS_FailedLoginAttempts] DEFAULT ((0)),
    [LockoutEnd] [datetime2](0) NULL,
    [MustChangePassword] [bit] NOT NULL CONSTRAINT [DF_USERS_MustChangePassword] DEFAULT ((1)),
    [PasswordChangedAt] [datetime2](0) NULL,
    [DateCreated] [datetime2](0) NOT NULL CONSTRAINT [DF_USERS_DateCreated] DEFAULT (sysdatetime()),
    [LastLogin] [datetime2](0) NULL,
    CONSTRAINT [PK_USERS] PRIMARY KEY CLUSTERED ([UserID] ASC),
    CONSTRAINT [UQ_USERS_Email] UNIQUE NONCLUSTERED ([Email] ASC),
    CONSTRAINT [UQ_USERS_Username] UNIQUE NONCLUSTERED ([Username] ASC),
    CONSTRAINT [CK_USERS_FailedLoginAttempts] CHECK ([FailedLoginAttempts]>=(0))
);
GO
CREATE NONCLUSTERED INDEX [IX_USERS_RoleID] ON [dbo].[USERS] ([RoleID] ASC);
GO

-- 4. FOREIGN KEYS
ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] WITH CHECK ADD CONSTRAINT [FK_ARDETAILS_AR] FOREIGN KEY ([ARID]) REFERENCES [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ([ARID]);
GO
ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] WITH CHECK ADD CONSTRAINT [FK_ARDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] WITH CHECK ADD CONSTRAINT [FK_AR_Issuer] FOREIGN KEY ([IssuedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] WITH CHECK ADD CONSTRAINT [FK_AR_Receiver] FOREIGN KEY ([ReceivedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] WITH CHECK ADD CONSTRAINT [FK_AR_Requisition] FOREIGN KEY ([RequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO
ALTER TABLE [dbo].[DELIVERIES] WITH CHECK ADD CONSTRAINT [FK_DELIVERIES_Generator] FOREIGN KEY ([GeneratedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DELIVERIES] WITH CHECK ADD CONSTRAINT [FK_DELIVERIES_Issuer] FOREIGN KEY ([IssuedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DELIVERIES] WITH CHECK ADD CONSTRAINT [FK_DELIVERIES_Requestor] FOREIGN KEY ([RequestorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DELIVERIES] WITH CHECK ADD CONSTRAINT [FK_DELIVERIES_Requisition] FOREIGN KEY ([RequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO
ALTER TABLE [dbo].[DELIVERIES] WITH CHECK ADD CONSTRAINT [FK_DELIVERIES_Signer] FOREIGN KEY ([SignedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DELIVERY_ITEMS] WITH CHECK ADD CONSTRAINT [FK_DELIVERY_ITEMS_Delivery] FOREIGN KEY ([DeliveryID]) REFERENCES [dbo].[DELIVERIES] ([DeliveryID]);
GO
ALTER TABLE [dbo].[DELIVERY_ITEMS] WITH CHECK ADD CONSTRAINT [FK_DELIVERY_ITEMS_Detail] FOREIGN KEY ([RequisitionDetailID]) REFERENCES [dbo].[REQUISITION_DETAILS] ([RequisitionDetailID]);
GO
ALTER TABLE [dbo].[DELIVERY_ITEMS] WITH CHECK ADD CONSTRAINT [FK_DELIVERY_ITEMS_Item] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] WITH CHECK ADD CONSTRAINT [FK_DRDETAILS_DR] FOREIGN KEY ([DRID]) REFERENCES [dbo].[DELIVERY_RECEIPTS] ([DRID]);
GO
ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] WITH CHECK ADD CONSTRAINT [FK_DRDETAILS_ITEM] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[DELIVERY_RECEIPTS] WITH CHECK ADD CONSTRAINT [FK_DR_PO] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[DELIVERY_SIGNATURE_HISTORY] WITH CHECK ADD CONSTRAINT [FK_DSH_Delivery] FOREIGN KEY ([DeliveryID]) REFERENCES [dbo].[DELIVERIES] ([DeliveryID]);
GO
ALTER TABLE [dbo].[DELIVERY_SIGNATURE_HISTORY] WITH CHECK ADD CONSTRAINT [FK_DSH_User] FOREIGN KEY ([UserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DOCUMENT_SIGNATURES] WITH CHECK ADD CONSTRAINT [FK_DOCUMENT_SIGNATURES_Revoker] FOREIGN KEY ([RevokedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[DOCUMENT_SIGNATURES] WITH CHECK ADD CONSTRAINT [FK_DOCUMENT_SIGNATURES_Signer] FOREIGN KEY ([SignerUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[EMAIL_LOGS] WITH CHECK ADD CONSTRAINT [FK_EMAIL_LOGS_PO] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[EMAIL_LOGS] WITH CHECK ADD CONSTRAINT [FK_EMAIL_LOGS_TriggeredBy] FOREIGN KEY ([TriggeredByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[EMAIL_SETTINGS] WITH CHECK ADD CONSTRAINT [FK_EMAIL_SETTINGS_UpdatedBy] FOREIGN KEY ([UpdatedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[INVENTORY] WITH CHECK ADD CONSTRAINT [FK_INVENTORY_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[INVENTORY_LOGS] WITH CHECK ADD CONSTRAINT [FK_INVENTORY_LOGS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[INVENTORY_LOGS] WITH CHECK ADD CONSTRAINT [FK_INVENTORY_LOGS_USERS] FOREIGN KEY ([UserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[INVENTORY_RESERVATIONS] WITH CHECK ADD CONSTRAINT [FK_RESERVATIONS_REQDETAILS] FOREIGN KEY ([RequisitionDetailID]) REFERENCES [dbo].[REQUISITION_DETAILS] ([RequisitionDetailID]);
GO
ALTER TABLE [dbo].[ITEMS] WITH CHECK ADD CONSTRAINT [FK_ITEMS_CATEGORIES] FOREIGN KEY ([CategoryID]) REFERENCES [dbo].[CATEGORIES] ([CategoryID]);
GO
ALTER TABLE [dbo].[NOTIFICATIONS] WITH CHECK ADD CONSTRAINT [FK_NOTIFICATIONS_RECIPIENT] FOREIGN KEY ([RecipientUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PO_PR_Mapping] WITH CHECK ADD CONSTRAINT [FK_PO_PR_Mapping_PO] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[PO_PR_Mapping] WITH CHECK ADD CONSTRAINT [FK_PO_PR_Mapping_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO
ALTER TABLE [dbo].[PURCHASE_BUDGETS] WITH CHECK ADD CONSTRAINT [FK_PURCHASE_BUDGETS_USER] FOREIGN KEY ([CreatedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PURCHASE_ORDERS] WITH CHECK ADD CONSTRAINT [FK_PO_Approver] FOREIGN KEY ([ApprovedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PURCHASE_ORDERS] WITH CHECK ADD CONSTRAINT [FK_PO_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO
ALTER TABLE [dbo].[PURCHASE_ORDERS] WITH CHECK ADD CONSTRAINT [FK_PO_Supplier] FOREIGN KEY ([SupplierID]) REFERENCES [dbo].[SUPPLIERS] ([SupplierID]);
GO
ALTER TABLE [dbo].[PURCHASE_REQUESTS] WITH CHECK ADD CONSTRAINT [FK_PURCHASE_REQUESTS_REPF] FOREIGN KEY ([RepFID]) REFERENCES [dbo].[REPLENISHMENT_REQUESTS] ([RepFID]);
GO
ALTER TABLE [dbo].[PURCHASE_REQUESTS] WITH CHECK ADD CONSTRAINT [FK_PURCHASE_REQUESTS_USERS] FOREIGN KEY ([CreatedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PURCHASING_DR_TRACKING] WITH CHECK ADD CONSTRAINT [FK__PURCHASIN__Recor__1EF99443] FOREIGN KEY ([RecordedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PURCHASING_DR_TRACKING] WITH CHECK ADD CONSTRAINT [FK__PURCHASING__DRID__1D114BD1] FOREIGN KEY ([DRID]) REFERENCES [dbo].[DELIVERY_RECEIPTS] ([DRID]);
GO
ALTER TABLE [dbo].[PURCHASING_DR_TRACKING] WITH CHECK ADD CONSTRAINT [FK__PURCHASING__POID__1E05700A] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[PURCHASING_FOLLOWUPS] WITH CHECK ADD CONSTRAINT [FK__PURCHASIN__SentB__1940BAED] FOREIGN KEY ([SentByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[PURCHASING_FOLLOWUPS] WITH CHECK ADD CONSTRAINT [FK__PURCHASING__POID__184C96B4] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[PURCHASING_PO_TRACKING] WITH CHECK ADD CONSTRAINT [FK__PURCHASING__POID__1387E197] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO
ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] WITH CHECK ADD CONSTRAINT [FK_RMDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] WITH CHECK ADD CONSTRAINT [FK_RMDETAILS_RM] FOREIGN KEY ([RMID]) REFERENCES [dbo].[RECEIVING_MEMOS] ([RMID]);
GO
ALTER TABLE [dbo].[RECEIVING_MEMOS] WITH CHECK ADD CONSTRAINT [FK_RM_DR] FOREIGN KEY ([DRID]) REFERENCES [dbo].[DELIVERY_RECEIPTS] ([DRID]);
GO
ALTER TABLE [dbo].[RECEIVING_MEMOS] WITH CHECK ADD CONSTRAINT [FK_RM_Receiver] FOREIGN KEY ([ReceivedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] WITH CHECK ADD CONSTRAINT [FK_REPF_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] WITH CHECK ADD CONSTRAINT [FK_REPF_OriginRequisition] FOREIGN KEY ([OriginRequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO
ALTER TABLE [dbo].[REPORT_AUDIT_LOGS] WITH CHECK ADD CONSTRAINT [FK_REPORT_AUDIT_LOGS_Actor] FOREIGN KEY ([ActorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[REQUISITION_DETAILS] WITH CHECK ADD CONSTRAINT [FK_REQDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO
ALTER TABLE [dbo].[REQUISITION_DETAILS] WITH CHECK ADD CONSTRAINT [FK_REQDETAILS_REQUISITIONS] FOREIGN KEY ([RequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO
ALTER TABLE [dbo].[REQUISITIONS] WITH CHECK ADD CONSTRAINT [FK_REQUISITIONS_Approver] FOREIGN KEY ([DepartmentHeadUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[REQUISITIONS] WITH CHECK ADD CONSTRAINT [FK_REQUISITIONS_Requestor] FOREIGN KEY ([RequestorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[ROLE_PERMISSIONS] WITH CHECK ADD CONSTRAINT [FK_ROLE_PERMISSIONS_PERMISSIONS] FOREIGN KEY ([PermissionID]) REFERENCES [dbo].[PERMISSIONS] ([PermissionID]);
GO
ALTER TABLE [dbo].[ROLE_PERMISSIONS] WITH CHECK ADD CONSTRAINT [FK_ROLE_PERMISSIONS_ROLES] FOREIGN KEY ([RoleID]) REFERENCES [dbo].[ROLES] ([RoleID]);
GO
ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] WITH CHECK ADD CONSTRAINT [FK_QUOTATIONS_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO
ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] WITH CHECK ADD CONSTRAINT [FK_QUOTATIONS_SUPPLIERS] FOREIGN KEY ([SupplierID]) REFERENCES [dbo].[SUPPLIERS] ([SupplierID]);
GO
ALTER TABLE [dbo].[USER_AUDIT_LOGS] WITH CHECK ADD CONSTRAINT [FK_USER_AUDIT_LOGS_Actor] FOREIGN KEY ([ActorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[USER_AUDIT_LOGS] WITH CHECK ADD CONSTRAINT [FK_USER_AUDIT_LOGS_Target] FOREIGN KEY ([TargetUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO
ALTER TABLE [dbo].[USERS] WITH CHECK ADD CONSTRAINT [FK_USERS_ROLES] FOREIGN KEY ([RoleID]) REFERENCES [dbo].[ROLES] ([RoleID]);
GO

-- 5. VIEWS
/* ============================================================
   1. PO SUMMARY VIEW â€” expose latest PO email status
   ============================================================ */

CREATE   VIEW dbo.vw_PurchasingWorkspacePO
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

-- 6. STORED PROCEDURES
-- Kani nga procedure para mo-log og user action sa audit trail.
CREATE   PROCEDURE usp_Audit_LogAction
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
CREATE   PROCEDURE usp_Dashboard_GetSummary
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

CREATE   PROCEDURE dbo.usp_Delivery_Complete
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanAcknowledge
       (
           @ActorUserID,
           @DeliveryID
       ) = 0
        THROW 50401,
            'Only the Requestor of this receipt or an Admin can acknowledge it.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50409,
            'Only an issued acknowledgement receipt can be signed and completed.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND IssuedByUserID IS NOT NULL
          AND NULLIF
              (
                  LTRIM(RTRIM(IssuedSignatureData)),
                  N''
              ) IS NOT NULL
    )
        THROW 50423,
            'The items must be issued with an inventory signature before the acknowledgement receipt can be completed.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50410,
            'A signature is required before completing the delivery.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50411,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50412,
            'The signature image is too large.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50417,
            'A discrepancy is still open. Re-issue the acknowledgement receipt after the item is replaced or the record is corrected.',
            1;

    DECLARE
        @RequisitionID INT,
        @RequestorUserID INT,
        @IssuedByUserID INT,
        @ARCode VARCHAR(30);

    SELECT
        @RequisitionID = RequisitionID,
        @RequestorUserID = RequestorUserID,
        @IssuedByUserID = IssuedByUserID,
        @ARCode = ARCode
    FROM dbo.DELIVERIES
    WHERE DeliveryID = @DeliveryID;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50404,
            'All requisition items must be fully allocated before completing the delivery.',
            1;

    BEGIN TRANSACTION;

    DECLARE @ItemID INT;
    DECLARE @DetailID INT;
    DECLARE @Quantity INT;
    DECLARE @OnHand INT;
    DECLARE @Reserved INT;
    DECLARE @ActiveReserved INT;

    DECLARE delivery_items CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            di.ItemID,
            di.RequisitionDetailID,
            di.Quantity
        FROM dbo.DELIVERY_ITEMS di
        WHERE di.DeliveryID = @DeliveryID;

    OPEN delivery_items;

    FETCH NEXT FROM delivery_items
    INTO @ItemID, @DetailID, @Quantity;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @OnHand = QuantityOnHand,
            @Reserved = QuantityReserved
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        IF @OnHand IS NULL
            THROW 50405,
                'No stock record exists for a delivery item.',
                1;

        SET @ActiveReserved = ISNULL
        (
            (
                SELECT SUM(r.QuantityReserved)
                FROM dbo.INVENTORY_RESERVATIONS r
                WHERE r.RequisitionDetailID = @DetailID
                  AND r.Status = N'Active'
            ),
            0
        );

        IF @ActiveReserved < @Quantity
           OR @Reserved < @Quantity
           OR @OnHand < @Quantity
            THROW 50405,
                'The reserved stock for a delivery item is no longer available. Correct the record and try again.',
                1;

        UPDATE dbo.INVENTORY
        SET QuantityOnHand = QuantityOnHand - @Quantity,
            QuantityReserved = QuantityReserved - @Quantity,
            LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        SELECT @OnHand = QuantityOnHand
        FROM dbo.INVENTORY
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS
        (
            ItemID,
            UserID,
            TransactionType,
            QuantityChange,
            PreviousQuantity,
            NewQuantity,
            ReferenceType,
            ReferenceID,
            Remarks,
            TransactionDate
        )
        VALUES
        (
            @ItemID,
            @ActorUserID,
            N'Stock Out',
            -@Quantity,
            @OnHand + @Quantity,
            @OnHand,
            N'DELIVERY',
            @DeliveryID,
            N'Items issued and delivered (acknowledgement receipt).',
            SYSDATETIME()
        );

        UPDATE dbo.INVENTORY_RESERVATIONS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID
          AND Status = N'Active';

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = N'Fulfilled'
        WHERE RequisitionDetailID = @DetailID;

        FETCH NEXT FROM delivery_items
        INTO @ItemID, @DetailID, @Quantity;
    END;

    CLOSE delivery_items;
    DEALLOCATE delivery_items;

    UPDATE dbo.DELIVERIES
    SET Status = N'Completed',
        SignedByUserID = @ActorUserID,
        SignedDate = SYSDATETIME(),
        ESignatureData = @Signature
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Received',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    UPDATE dbo.REQUISITIONS
    SET Status = N'Fulfilled'
    WHERE RequisitionID = @RequisitionID;

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    VALUES
    (
        @RequestorUserID,
        'REQUISITION_FULFILLED',
        'Requisition fulfilled',
        'Your requested items have been delivered and your requisition is now fulfilled.',
        'REQUISITION',
        @RequisitionID,
        0,
        SYSDATETIME()
    );

    /* Notify the issuer / delivery managers that the requestor signed and completed the AR */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        targets.UserID,
        'DELIVERY_COMPLETED',
        'Acknowledgement receipt completed',
        CONCAT(
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            ' for requisition #',
            @RequisitionID,
            ' was signed and completed.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM
    (
        SELECT u.UserID
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND p.PermissionCode = N'delivery.manage'
        UNION
        SELECT @IssuedByUserID
        WHERE @IssuedByUserID IS NOT NULL
    ) targets
    WHERE targets.UserID <> @ActorUserID;

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
        @RequestorUserID,
        'DELIVERY_COMPLETED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' signed electronically; requisition #',
            @RequisitionID,
            ' fulfilled.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

/* AR Complete + generic signature store sync. */
CREATE   PROCEDURE dbo.usp_Delivery_CompleteWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before completing the delivery.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_Complete
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Signature = @SignatureImage;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT',
            @DocumentID = @DeliveryID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   8. GENERATE ACKNOWLEDGEMENT RECEIPT
   Inventory Staff or Admin.
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Delivery_GenerateAR
    @ActorUserID INT,
    @RequisitionID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can generate acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
          AND Status = N'Approved'
    )
        THROW 50402,
            'Only an approved requisition can receive an acknowledgement receipt.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Generated',
              N'Issued'
          )
    )
        THROW 50403,
            'This requisition already has an open acknowledgement receipt.',
            1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50404,
            'All requisition items must be fully allocated before generating an acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
    )
        THROW 50405,
            'This requisition has no items to deliver.',
            1;

    BEGIN TRANSACTION;

    DECLARE @MaxNum INT =
    (
        SELECT MAX
        (
            TRY_CAST
            (
                SUBSTRING(ARCode, 4, 10) AS INT
            )
        )
        FROM dbo.DELIVERIES
        WHERE ARCode LIKE 'AR-[0-9]%'
    );

    DECLARE @ARCode VARCHAR(30) =
        'AR-' +
        RIGHT
        (
            '0000' +
            CAST
            (
                ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)
            ),
            4
        );

    WHILE EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE ARCode = @ARCode
    )
    BEGIN
        SET @MaxNum = ISNULL(@MaxNum, 0) + 1;

        SET @ARCode =
            'AR-' +
            RIGHT
            (
                '0000' +
                CAST(@MaxNum AS VARCHAR(10)),
                4
            );
    END;

    DECLARE @RequestorUserID INT =
    (
        SELECT RequestorUserID
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
    );

    INSERT INTO dbo.DELIVERIES
    (
        ARCode,
        RequisitionID,
        RequestorUserID,
        GeneratedByUserID,
        GeneratedDate,
        Status
    )
    VALUES
    (
        @ARCode,
        @RequisitionID,
        @RequestorUserID,
        @ActorUserID,
        SYSDATETIME(),
        N'Generated'
    );

    DECLARE @DeliveryID INT = SCOPE_IDENTITY();

    INSERT INTO dbo.DELIVERY_ITEMS
    (
        DeliveryID,
        RequisitionDetailID,
        ItemID,
        Quantity
    )
    SELECT
        @DeliveryID,
        rd.RequisitionDetailID,
        rd.ItemID,
        ISNULL
        (
            rd.QuantityApproved,
            rd.QuantityRequested
        )
    FROM dbo.REQUISITION_DETAILS rd
    WHERE rd.RequisitionID = @RequisitionID;

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
        @RequestorUserID,
        'DELIVERY_AR_GENERATED',
        CONCAT
        (
            'Acknowledgement receipt ',
            @ARCode,
            ' generated for requisition #',
            @RequisitionID,
            '.'
        )
    );

    COMMIT TRANSACTION;

    SELECT
        @DeliveryID AS DeliveryID,
        @ARCode AS ARCode;
END;
GO

/* 
   1. CORRECTION REPORT — include Requestor & Issued By signatures
 */

CREATE   PROCEDURE dbo.usp_Delivery_GetCorrectionReport
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('delivery.view', 'delivery.manage')
    )
        THROW 50606,
            'You do not have permission to print correction reports.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    )
        RETURN;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
       AND NOT EXISTS
       (
           SELECT 1
           FROM dbo.DELIVERIES
           WHERE DeliveryID = @DeliveryID
             AND RequestorUserID = @ActorUserID
       )
        THROW 50607,
            'You can only view correction reports for your own acknowledgement receipts.',
            1;

    /* Result set 1 correction report header + AR digital signatures. */
    SELECT
        d.DeliveryID,
        d.ARCode,
        d.RequisitionID,
        LTRIM(RTRIM(CONCAT(
            requestor.FirstName, ' ', requestor.LastName
        ))) AS RequestorName,
        CASE
            WHEN head.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                head.FirstName, ' ', head.LastName
            )))
        END AS DepartmentHeadName,
        CASE
            WHEN issuer.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                issuer.FirstName, ' ', issuer.LastName
            )))
        END AS IssuedByName,
        LTRIM(RTRIM(CONCAT(
            generatedBy.FirstName, ' ', generatedBy.LastName
        ))) AS GeneratedByName,
        CASE
            WHEN correctedBy.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                correctedBy.FirstName, ' ', correctedBy.LastName
            )))
        END AS CorrectedByName,
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        d.Status,
        d.DiscrepancyNotes,
        d.DiscrepancyResolvedAt,
        d.CorrectionNotes,
        d.CorrectedAt,
        r.Justification,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline,
        CASE
            WHEN signedUser.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                signedUser.FirstName, ' ', signedUser.LastName
            )))
        END AS SignedByName,
        d.ESignatureData AS RequestorSignatureData,
        d.IssuedSignatureData
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.REQUISITIONS r
        ON r.RequisitionID = d.RequisitionID
    INNER JOIN dbo.USERS requestor
        ON requestor.UserID = d.RequestorUserID
    INNER JOIN dbo.USERS generatedBy
        ON generatedBy.UserID = d.GeneratedByUserID
    LEFT JOIN dbo.USERS head
        ON head.UserID = r.DepartmentHeadUserID
    LEFT JOIN dbo.USERS issuer
        ON issuer.UserID = d.IssuedByUserID
    LEFT JOIN dbo.USERS correctedBy
        ON correctedBy.UserID = d.CorrectedByUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    WHERE d.DeliveryID = @DeliveryID;

    /* Result set 2 AR line items. */
    SELECT
        di.DeliveryItemID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        di.Quantity
    FROM dbo.DELIVERY_ITEMS di
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = di.ItemID
    WHERE di.DeliveryID = @DeliveryID
    ORDER BY di.DeliveryItemID;

    /* Result set 3 preserved signature history (audit trail). */
    SELECT
        h.Stage,
        h.SignedAt,
        LTRIM(RTRIM(CONCAT(
            u.FirstName, ' ', u.LastName
        ))) AS UserName
    FROM dbo.DELIVERY_SIGNATURE_HISTORY h
    INNER JOIN dbo.USERS u
        ON u.UserID = h.UserID
    WHERE h.DeliveryID = @DeliveryID
    ORDER BY h.SignatureHistoryID;
END;
GO

CREATE   PROCEDURE dbo.usp_Delivery_GetOverview
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50400,
            'You do not have permission to view deliveries.',
            1;

    DECLARE @CanManage BIT = dbo.fn_DeliveryCanManage(@ActorUserID);

    /* Result set 1: fully allocated requisitions (Admin & Inventory Staff only). */

    SELECT
        r.RequisitionID,
        CONCAT
        (
            reqUser.FirstName,
            ' ',
            reqUser.LastName
        ) AS RequestorName,
        r.RequestDate,
        r.RequiredDate,
        r.Justification,
        (
            SELECT STRING_AGG
            (
                CONCAT
                (
                    i.ItemName,
                    N' (Qty: ',
                    CAST
                    (
                        ISNULL
                        (
                            rd.QuantityApproved,
                            rd.QuantityRequested
                        ) AS NVARCHAR(20)
                    ),
                    N')'
                ),
                N'; '
            )
            WITHIN GROUP
            (
                ORDER BY rd.RequisitionDetailID
            )
            FROM dbo.REQUISITION_DETAILS rd
            INNER JOIN dbo.ITEMS i
                ON i.ItemID = rd.ItemID
            WHERE rd.RequisitionID = r.RequisitionID
        ) AS ItemsSummary
    FROM dbo.REQUISITIONS r
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = r.RequestorUserID
    WHERE @CanManage = 1
      AND r.Status = N'Approved'
      AND EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITION_DETAILS rd
          WHERE rd.RequisitionID = r.RequisitionID
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITION_DETAILS rd
          WHERE rd.RequisitionID = r.RequisitionID
            AND rd.Status IN
            (
                N'Pending',
                N'Partially Fulfilled'
            )
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.DELIVERIES d
          WHERE d.RequisitionID = r.RequisitionID
            AND d.Status IN
            (
                N'Generated',
                N'Issued'
            )
      )
    ORDER BY r.RequestDate;

    /* Result set 2: acknowledgement receipts.
       Delivery managers (Admin, Inventory Staff) see all receipts;
       other users (including Staff) ONLY see their own receipts. */

    SELECT
        d.DeliveryID,
        d.ARCode,
        d.RequisitionID,
        CONCAT
        (
            reqUser.FirstName,
            ' ',
            reqUser.LastName
        ) AS RequestorName,
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        CONCAT
        (
            signedUser.FirstName,
            ' ',
            signedUser.LastName
        ) AS SignedByName,
        d.DiscrepancyNotes,
        d.Status,
        (
            SELECT STRING_AGG
            (
                CONCAT
                (
                    i.ItemName,
                    N' (Qty: ',
                    CAST(di.Quantity AS NVARCHAR(20)),
                    N')'
                ),
                N'; '
            )
            WITHIN GROUP
            (
                ORDER BY di.DeliveryItemID
            )
            FROM dbo.DELIVERY_ITEMS di
            INNER JOIN dbo.ITEMS i
                ON i.ItemID = di.ItemID
            WHERE di.DeliveryID = d.DeliveryID
        ) AS ItemsSummary,
        CAST
        (
            CASE
                WHEN d.ESignatureData IS NULL THEN 0
                ELSE 1
            END AS BIT
        ) AS HasSignature,
        CAST
        (
            CASE
                WHEN NULLIF
                     (
                         LTRIM(RTRIM(d.DiscrepancyNotes)),
                         N''
                     ) IS NOT NULL
                 AND d.DiscrepancyResolvedAt IS NULL
                    THEN 1
                ELSE 0
            END AS BIT
        ) AS HasUnresolvedDiscrepancy,
        d.DiscrepancyResolvedAt,
        dbo.fn_DeliveryCanAcknowledge
        (
            @ActorUserID,
            d.DeliveryID
        ) AS CanAcknowledge,
        d.CorrectedAt,
        d.CorrectionNotes,
        CONCAT
        (
            correctedUser.FirstName,
            ' ',
            correctedUser.LastName
        ) AS CorrectedByName
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    LEFT JOIN dbo.USERS correctedUser
        ON correctedUser.UserID = d.CorrectedByUserID
    WHERE @CanManage = 1
       OR d.RequestorUserID = @ActorUserID
    ORDER BY
        d.GeneratedDate DESC,
        d.DeliveryID DESC;
END;
GO

CREATE   PROCEDURE dbo.usp_Delivery_GetReceipt
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50410,
            'You do not have permission to view acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    )
        RETURN;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
       AND NOT EXISTS
       (
           SELECT 1
           FROM dbo.DELIVERIES
           WHERE DeliveryID = @DeliveryID
             AND RequestorUserID = @ActorUserID
       )
        THROW 50411,
            'You can only view your own acknowledgement receipts.',
            1;

    /* Result set 1: receipt header. */
    SELECT
        d.DeliveryID,
        d.ARCode,
        d.RequisitionID,
        CONCAT
        (
            reqUser.FirstName,
            ' ',
            reqUser.LastName
        ) AS RequestorName,
        CASE
            WHEN headUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                headUser.FirstName,
                ' ',
                headUser.LastName
            )
        END AS DepartmentHeadName,
        CONCAT
        (
            genUser.FirstName,
            ' ',
            genUser.LastName
        ) AS GeneratedByName,
        CASE
            WHEN signedUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                signedUser.FirstName,
                ' ',
                signedUser.LastName
            )
        END AS SignedByName,
        CASE
            WHEN correctedUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                correctedUser.FirstName,
                ' ',
                correctedUser.LastName
            )
        END AS CorrectedByName,
        r.RequestDate,
        r.RequiredDate,
        r.Justification,
        d.GeneratedDate,
        d.IssuedDate,
        d.SignedDate,
        d.Status,
        d.DiscrepancyNotes,
        d.CorrectionNotes,
        d.ESignatureData AS SignatureData,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline,
        CASE
            WHEN issuerUser.UserID IS NULL THEN NULL
            ELSE CONCAT
            (
                issuerUser.FirstName,
                ' ',
                issuerUser.LastName
            )
        END AS IssuedByName,
        d.IssuedSignatureData,
        r.ApprovedDate,
        r.ApprovalSignatureData
    FROM dbo.DELIVERIES d
    INNER JOIN dbo.REQUISITIONS r
        ON r.RequisitionID = d.RequisitionID
    INNER JOIN dbo.USERS reqUser
        ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN dbo.USERS headUser
        ON headUser.UserID = r.DepartmentHeadUserID
    INNER JOIN dbo.USERS genUser
        ON genUser.UserID = d.GeneratedByUserID
    LEFT JOIN dbo.USERS signedUser
        ON signedUser.UserID = d.SignedByUserID
    LEFT JOIN dbo.USERS correctedUser
        ON correctedUser.UserID = d.CorrectedByUserID
    LEFT JOIN dbo.USERS issuerUser
        ON issuerUser.UserID = d.IssuedByUserID
    WHERE d.DeliveryID = @DeliveryID;

    /* Result set 2: receipt line items. */
    SELECT
        di.DeliveryItemID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        di.Quantity
    FROM dbo.DELIVERY_ITEMS di
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = di.ItemID
    WHERE di.DeliveryID = @DeliveryID
    ORDER BY di.DeliveryItemID;
END;
GO

CREATE   PROCEDURE dbo.usp_Delivery_GetSignature
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50400, 'You do not have permission to view deliveries.', 1;

    IF NOT EXISTS (SELECT 1 FROM DELIVERIES WHERE DeliveryID = @DeliveryID)
        THROW 50416, 'The acknowledgement receipt was not found.', 1;

    SELECT d.DeliveryID,
           d.ARCode,
           d.Status,
           d.SignedDate,
           CONCAT(u.FirstName, ' ', u.LastName) AS SignedByName,
           d.ESignatureData
    FROM DELIVERIES d
    LEFT JOIN USERS u ON u.UserID = d.SignedByUserID
    WHERE d.DeliveryID = @DeliveryID;
END;
GO

/* ============================================================
   6. DELIVERY ISSUED, DISCREPANCY, REISSUE, COMPLETE & AUTO-MARK
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Delivery_MarkIssued
    @ActorUserID INT,
    @DeliveryID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can issue delivery items.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Generated'
    )
        THROW 50406,
            'Only a generated acknowledgement receipt can be marked as issued.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
        THROW 50420,
            'A signature is required before issuing the items.',
            1;

    IF @Signature NOT LIKE N'data:image/%'
        THROW 50421,
            'The signature image is not valid.',
            1;

    IF LEN(@Signature) > 2000000
        THROW 50422,
            'The signature image is too large.',
            1;

    BEGIN TRANSACTION;

    DECLARE @RequestorUserID INT;
    DECLARE @ARCode VARCHAR(30);
    DECLARE @RequisitionID INT;

    SELECT
        @RequestorUserID = d.RequestorUserID,
        @ARCode = d.ARCode,
        @RequisitionID = d.RequisitionID
    FROM dbo.DELIVERIES d
    WHERE d.DeliveryID = @DeliveryID;

    UPDATE dbo.DELIVERIES
    SET Status = N'Issued',
        IssuedByUserID = @ActorUserID,
        IssuedSignatureData = @Signature,
        IssuedDate = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

    INSERT INTO dbo.DELIVERY_SIGNATURE_HISTORY
    (
        DeliveryID,
        Stage,
        UserID,
        SignatureData,
        SignedAt
    )
    VALUES
    (
        @DeliveryID,
        'Issued',
        @ActorUserID,
        @Signature,
        SYSDATETIME()
    );

    /* Notify the requestor that their items have been issued for inspection and e-signature */
    IF @RequestorUserID IS NOT NULL AND @RequestorUserID <> @ActorUserID
    BEGIN
        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID,
            IsRead,
            CreatedAt
        )
        VALUES
        (
            @RequestorUserID,
            'DELIVERY_ISSUED',
            'Items issued for delivery',
            CONCAT(
                'Acknowledgement receipt ',
                ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
                ' for requisition #',
                @RequisitionID,
                ' has been issued. Inspect your items and e-sign in Delivery.'
            ),
            'DELIVERY',
            @DeliveryID,
            0,
            SYSDATETIME()
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
        ISNULL(@RequestorUserID, @ActorUserID),
        'DELIVERY_ISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' marked as issued with an inventory signature.'
        )
    );

    COMMIT TRANSACTION;
END;
GO

/* AR Issue + generic signature store sync. Kung re-issued ang AR,
   i-supersede ang daan nga active Issued signature (audit history kept). */
CREATE   PROCEDURE dbo.usp_Delivery_MarkIssuedWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before issuing the items.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_MarkIssued
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Signature = @SignatureImage;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = N'Superseded by re-issuance after correction.'
        WHERE DocumentType = 'ACKNOWLEDGEMENT_RECEIPT'
          AND DocumentID = @DeliveryID
          AND Stage = 'Issued'
          AND IsActive = 1;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'ACKNOWLEDGEMENT_RECEIPT',
            @DocumentID = @DeliveryID,
            @Stage = 'Issued',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE dbo.usp_Delivery_NoteDiscrepancy
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanAcknowledge
       (
           @ActorUserID,
           @DeliveryID
       ) = 0
        THROW 50401,
            'Only the Requestor of this receipt or an Admin can acknowledge it.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
        THROW 50407,
            'A discrepancy note is required.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50408,
            'A discrepancy can only be noted on an issued acknowledgement receipt.',
            1;

    DECLARE @ARCode VARCHAR(30) = (SELECT ARCode FROM dbo.DELIVERIES WHERE DeliveryID = @DeliveryID);

    UPDATE dbo.DELIVERIES
    SET DiscrepancyNotes = LTRIM(RTRIM(@Notes)),
        DiscrepancyResolvedAt = NULL,
        CorrectedAt = NULL,
        CorrectedByUserID = NULL,
        CorrectionNotes = NULL
    WHERE DeliveryID = @DeliveryID;

    /* Notify delivery.manage team (Inventory Staff / Admin), not Purchasing Staff */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'DELIVERY_DISCREPANCY',
        'Delivery discrepancy noted',
        CONCAT(
            'A discrepancy was noted on ',
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            '. The item may need replacement or record correction.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1
      AND u.UserID <> @ActorUserID
      AND p.PermissionCode = N'delivery.manage';

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
        'DELIVERY_DISCREPANCY',
        CONCAT
        (
            'Discrepancy noted on acknowledgement receipt #',
            @DeliveryID,
            '.'
        )
    );
END;
GO

/* ============================================================
   4. RECORD CORRECTION
   Inventory Staff or Admin.
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Delivery_RecordCorrection
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can record delivery corrections.',
            1;

    IF NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
        THROW 50419,
            'The correction details are required.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50408,
            'A correction can only be recorded on an issued acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50414,
            'Note the discrepancy first before recording a correction.',
            1;

    UPDATE dbo.DELIVERIES
    SET CorrectedAt = SYSDATETIME(),
        CorrectedByUserID = @ActorUserID,
        CorrectionNotes = LTRIM(RTRIM(@Notes))
    WHERE DeliveryID = @DeliveryID;

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
        NULL,
        'DELIVERY_CORRECTED',
        CONCAT
        (
            'Item replacement/record correction recorded on acknowledgement receipt #',
            @DeliveryID,
            '.'
        )
    );
END;
GO

/* Correction Report + signature. Kung naay existing active correction
   signature, i-supersede kini (revoked row preserved) kay ang correction
   pwede pa ma-update samtang wala pa na-resolve ang discrepancy. */
CREATE   PROCEDURE dbo.usp_Delivery_RecordCorrectionWithSignature
    @ActorUserID INT,
    @DeliveryID INT,
    @Notes NVARCHAR(500),
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before saving the correction.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50734,
            'A signature is required to record a correction.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Delivery_RecordCorrection
            @ActorUserID = @ActorUserID,
            @DeliveryID = @DeliveryID,
            @Notes = @Notes;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = N'Superseded by a newer correction record.'
        WHERE DocumentType = 'CORRECTION_REPORT'
          AND DocumentID = @DeliveryID
          AND Stage = 'Corrected'
          AND IsActive = 1;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'CORRECTION_REPORT',
            @DocumentID = @DeliveryID,
            @Stage = 'Corrected',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Kani nga procedure para i-record ang delivery receipt sa approved o sent nga PO.
CREATE   PROCEDURE usp_Delivery_RecordDR
    @POID INT,
    @Status VARCHAR(30) = 'Accepted',
    @Notes NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Accepted', 'With Discrepancies', 'Rejected')
        THROW 50160, 'The delivery status is invalid.', 1;

    IF NOT EXISTS (SELECT 1 FROM PURCHASE_ORDERS WHERE POID = @POID AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered'))
        THROW 50161, 'The purchase order (PO) must be approved or already sent to the supplier.', 1;

    INSERT INTO DELIVERY_RECEIPTS (POID, Status, Notes)
    VALUES (@POID, @Status, @Notes);

    SELECT SCOPE_IDENTITY() AS DRID;
END;
GO

CREATE   PROCEDURE dbo.usp_Delivery_Reissue
    @ActorUserID INT,
    @DeliveryID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF dbo.fn_DeliveryCanManage(@ActorUserID) = 0
        THROW 50401,
            'Only Inventory Staff or Admin can re-issue acknowledgement receipts.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND Status = N'Issued'
    )
        THROW 50413,
            'Only an issued acknowledgement receipt can be re-issued.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND NULLIF
              (
                  LTRIM(RTRIM(DiscrepancyNotes)),
                  N''
              ) IS NOT NULL
          AND DiscrepancyResolvedAt IS NULL
    )
        THROW 50414,
            'Note the discrepancy first before re-issuing the acknowledgement receipt.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
          AND CorrectedAt IS NOT NULL
    )
        THROW 50418,
            'Record the item replacement or record correction before re-issuing the acknowledgement receipt.',
            1;

    DECLARE @RequisitionID INT;
    DECLARE @RequestorUserID INT;
    DECLARE @ARCode VARCHAR(30);

    SELECT
        @RequisitionID = RequisitionID,
        @RequestorUserID = RequestorUserID,
        @ARCode = ARCode
    FROM dbo.DELIVERIES
    WHERE DeliveryID = @DeliveryID;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITION_DETAILS
        WHERE RequisitionID = @RequisitionID
          AND Status IN
          (
              N'Pending',
              N'Partially Fulfilled'
          )
    )
        THROW 50415,
            'Correct the requisition allocation before re-issuing the acknowledgement receipt.',
            1;

    BEGIN TRANSACTION;

    UPDATE dbo.DELIVERIES
    SET Status = N'Generated',
        IssuedDate = NULL,
        IssuedByUserID = NULL,
        IssuedSignatureData = NULL,
        SignedByUserID = NULL,
        SignedDate = NULL,
        DiscrepancyResolvedAt = SYSDATETIME()
    WHERE DeliveryID = @DeliveryID;

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
        ISNULL(@RequestorUserID, @ActorUserID),
        'DELIVERY_REISSUED',
        CONCAT
        (
            'Acknowledgement receipt #',
            @DeliveryID,
            ' returned to Generated for re-issue after a discrepancy; requisition #',
            @RequisitionID,
            '.'
        )
    );

    /* Notify delivery.manage team (when re-issuance needs re-issuing) and requestor */
    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        targets.UserID,
        'DELIVERY_REISSUED',
        'Acknowledgement receipt re-issued',
        CONCAT
        (
            ISNULL(@ARCode, CONCAT('AR #', @DeliveryID)),
            ' was returned for correction and is ready to be issued again.'
        ),
        'DELIVERY',
        @DeliveryID,
        0,
        SYSDATETIME()
    FROM
    (
        SELECT u.UserID
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND p.PermissionCode = N'delivery.manage'
        UNION
        SELECT @RequestorUserID
        WHERE @RequestorUserID IS NOT NULL
          AND @RequestorUserID <> @ActorUserID
    ) targets;

    COMMIT TRANSACTION;
END;
GO

CREATE   PROCEDURE usp_Delivery_SaveDetail
    @DRID INT,
    @ItemID INT,
    @QuantityDelivered INT,
    @QuantityAccepted INT,
    @QuantityRejected INT,
    @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityDelivered <= 0 OR @QuantityAccepted < 0 OR @QuantityRejected < 0
       OR @QuantityAccepted + @QuantityRejected > @QuantityDelivered
        THROW 50330, 'The delivered, accepted, or rejected quantity is invalid.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @POID INT, @OrderedQty INT, @AlreadyAccepted INT;
        SELECT @POID = dr.POID
        FROM DELIVERY_RECEIPTS dr WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN PURCHASE_ORDERS po ON po.POID = dr.POID
        WHERE dr.DRID = @DRID AND po.Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered');

        IF @POID IS NULL
            THROW 50331, 'No valid delivery receipt was found, or the purchase order (PO) has not yet been approved.', 1;

        IF NOT EXISTS (
            SELECT 1 FROM PO_PR_Mapping m
            INNER JOIN PURCHASE_REQUESTS pr ON pr.PRID = m.PRID
            INNER JOIN REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
            WHERE m.POID = @POID AND rr.ItemID = @ItemID
        ) AND NOT EXISTS (
            SELECT 1 FROM PURCHASE_ORDERS po
            INNER JOIN PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
            INNER JOIN REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
            WHERE po.POID = @POID AND rr.ItemID = @ItemID
        )
            THROW 50332, 'The item is not included in the purchase order (PO).', 1;

        SELECT @OrderedQty = QuantityOrdered FROM PURCHASE_ORDERS WHERE POID = @POID;
        SELECT @AlreadyAccepted = ISNULL(SUM(drd.QuantityAccepted), 0)
        FROM DELIVERY_RECEIPT_DETAILS drd
        INNER JOIN DELIVERY_RECEIPTS dr ON dr.DRID = drd.DRID
        WHERE dr.POID = @POID AND NOT (dr.DRID = @DRID AND drd.ItemID = @ItemID);

        IF @AlreadyAccepted + @QuantityAccepted > @OrderedQty
            THROW 50333, 'The accepted quantity exceeds the quantity ordered.', 1;

        IF EXISTS (SELECT 1 FROM DELIVERY_RECEIPT_DETAILS WHERE DRID = @DRID AND ItemID = @ItemID)
            UPDATE DELIVERY_RECEIPT_DETAILS
            SET QuantityDelivered = @QuantityDelivered, QuantityAccepted = @QuantityAccepted,
                QuantityRejected = @QuantityRejected, Remarks = @Remarks
            WHERE DRID = @DRID AND ItemID = @ItemID;
        ELSE
            INSERT INTO DELIVERY_RECEIPT_DETAILS (DRID, ItemID, QuantityDelivered, QuantityAccepted, QuantityRejected, Remarks)
            VALUES (@DRID, @ItemID, @QuantityDelivered, @QuantityAccepted, @QuantityRejected, @Remarks);

        IF @QuantityRejected > 0 OR @QuantityAccepted < @QuantityDelivered
            UPDATE DELIVERY_RECEIPTS SET Status = 'With Discrepancies' WHERE DRID = @DRID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE dbo.usp_DocumentSignature_Get
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS
        WHERE UserID = @ActorUserID
          AND IsActive = 1
    )
        THROW 50720, 'Your session is no longer active.', 1;

    DECLARE @CurrentHash CHAR(64) =
        dbo.fn_DocumentSignatureHash(@DocumentType, @DocumentID);

    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        s.StageLabel,
        s.RoleLabel,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.SignatureImage,
        ds.DocumentHash,
        @CurrentHash AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = @CurrentHash
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.DOCUMENT_SIGNATURES ds
    LEFT JOIN dbo.DOCUMENT_SIGNATURE_STAGES s
        ON s.DocumentType = ds.DocumentType
       AND s.Stage = ds.Stage
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1
    UNION ALL
    /* Para sa Receiving Report nga gikan sa Checked DR, i-apil ang
       Checked-by signature gikan sa Purchasing Delivery Check (by process). */
    SELECT TOP (1)
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        'Checked' AS Stage,
        N'Checked by' AS StageLabel,
        N'Checker' AS RoleLabel,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.SignatureImage,
        ds.DocumentHash,
        dbo.fn_DocumentSignatureHash('DELIVERY_CHECK', ds.DocumentID) AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash('DELIVERY_CHECK', ds.DocumentID)
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.INVENTORY_LOGS l
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON l.ReferenceType = 'REPLENISHMENT'
       AND pr.RepFID = l.ReferenceID
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.PRID = pr.PRID
    INNER JOIN dbo.DELIVERY_RECEIPTS dr
        ON dr.POID = po.POID
    INNER JOIN dbo.DOCUMENT_SIGNATURES ds
        ON ds.DocumentType = 'DELIVERY_CHECK'
       AND ds.DocumentID = dr.DRID
       AND ds.Stage = 'Checked'
       AND ds.IsActive = 1
    WHERE @DocumentType = 'RECEIVING_REPORT'
      AND l.InventoryLogID = @DocumentID
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.DOCUMENT_SIGNATURES existing
          WHERE existing.DocumentType = 'RECEIVING_REPORT'
            AND existing.DocumentID = @DocumentID
            AND existing.Stage = 'Checked'
            AND existing.IsActive = 1
      )
    ORDER BY ds.SignatureID DESC;
END;
GO

/* 
   4. UNIFIED PRINT SIGNATURE PACK (DIRECT + LINKED FALLBACKS)
 */

CREATE   PROCEDURE dbo.usp_DocumentSignature_GetPrintPack
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS
        WHERE UserID = @ActorUserID AND IsActive = 1
    )
        THROW 50711, 'Your session is no longer active.', 1;

    DECLARE @Result TABLE
    (
        SignatureID BIGINT NULL,
        DocumentType VARCHAR(40) NOT NULL,
        DocumentID INT NOT NULL,
        Stage VARCHAR(40) NOT NULL,
        StageLabel NVARCHAR(80) NULL,
        SignerUserID INT NULL,
        SignerName NVARCHAR(200) NULL,
        SignerRole NVARCHAR(100) NULL,
        SignatureImage NVARCHAR(MAX) NULL,
        DocumentHash CHAR(64) NULL,
        SignedAt DATETIME2(0) NULL,
        IsHashValid BIT NOT NULL DEFAULT (1),
        SortOrder INT NOT NULL DEFAULT (0)
    );

    /* Direct active signatures on the document itself. */
    INSERT INTO @Result
    (
        SignatureID, DocumentType, DocumentID, Stage, StageLabel,
        SignerUserID, SignerName, SignerRole, SignatureImage,
        DocumentHash, SignedAt, IsHashValid, SortOrder
    )
    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        ISNULL(st.StageLabel, ds.Stage),
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignatureImage,
        ds.DocumentHash,
        ds.SignedAt,
        CAST(CASE
            WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID)
                THEN 1 ELSE 0
        END AS BIT),
        ISNULL(st.SortOrder, 50)
    FROM dbo.DOCUMENT_SIGNATURES ds
    LEFT JOIN dbo.DOCUMENT_SIGNATURE_STAGES st
        ON st.DocumentType = ds.DocumentType
       AND st.Stage = ds.Stage
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1;

    /*  PURCHASE_ORDER: fallback Requested from linked RepF Approved (Create PR) */
    IF @DocumentType = 'PURCHASE_ORDER'
       AND NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Requested')
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'PURCHASE_ORDER',
            @DocumentID,
            'Requested',
            N'Requested by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            5
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr
            ON pr.PRID = po.PRID
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'REPLENISHMENT_REQUEST'
           AND ds.DocumentID = pr.RepFID
           AND ds.Stage = 'Approved'
           AND ds.IsActive = 1
        WHERE po.POID = @DocumentID
        ORDER BY ds.SignatureID DESC;
    END;

    /*  RETURN_SLIP (@DocumentID = DRID): Recorded (DR Checked or RepF Approved) + Approved (PO Approved)  */
    IF @DocumentType = 'RETURN_SLIP'
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'RETURN_SLIP',
            @DocumentID,
            'Recorded',
            N'Recorded by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            10
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE ds.DocumentType = 'DELIVERY_CHECK'
          AND ds.DocumentID = @DocumentID
          AND ds.Stage = 'Checked'
          AND ds.IsActive = 1
        ORDER BY ds.SignatureID DESC;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Recorded')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RETURN_SLIP',
                @DocumentID,
                'Recorded',
                N'Recorded by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                10
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
            INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'REPLENISHMENT_REQUEST'
               AND ds.DocumentID = pr.RepFID
               AND ds.Stage = 'Approved'
               AND ds.IsActive = 1
            WHERE dr.DRID = @DocumentID
            ORDER BY ds.SignatureID DESC;
        END;

        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'RETURN_SLIP',
            @DocumentID,
            'Approved',
            N'Approved by',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            30
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'PURCHASE_ORDER'
           AND ds.DocumentID = dr.POID
           AND ds.Stage = 'Approved'
           AND ds.IsActive = 1
        WHERE dr.DRID = @DocumentID
        ORDER BY ds.SignatureID DESC;
    END;

    /*  RECEIVING_REPORT (@DocumentID = InventoryLogID):
           Checked  -> fallback from linked DELIVERY_CHECK Checked (Purchasing Staff)
           Approved -> fallback from linked PURCHASE_ORDER Approved (Manager)  */
    IF @DocumentType = 'RECEIVING_REPORT'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Checked')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RECEIVING_REPORT',
                @DocumentID,
                'Checked',
                N'Checked by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                20
            FROM dbo.INVENTORY_LOGS l
            INNER JOIN dbo.PURCHASE_REQUESTS pr
                ON l.ReferenceType = 'REPLENISHMENT'
               AND pr.RepFID = l.ReferenceID
            INNER JOIN dbo.PURCHASE_ORDERS po
                ON po.PRID = pr.PRID
            INNER JOIN dbo.DELIVERY_RECEIPTS dr
                ON dr.POID = po.POID
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'DELIVERY_CHECK'
               AND ds.DocumentID = dr.DRID
               AND ds.Stage = 'Checked'
               AND ds.IsActive = 1
            WHERE l.InventoryLogID = @DocumentID
            ORDER BY dr.DRID DESC, ds.SignatureID DESC;
        END;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Approved')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'RECEIVING_REPORT',
                @DocumentID,
                'Approved',
                N'Approved by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                30
            FROM dbo.INVENTORY_LOGS l
            INNER JOIN dbo.PURCHASE_REQUESTS pr
                ON l.ReferenceType = 'REPLENISHMENT'
               AND pr.RepFID = l.ReferenceID
            INNER JOIN dbo.PURCHASE_ORDERS po
                ON po.PRID = pr.PRID
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'PURCHASE_ORDER'
               AND ds.DocumentID = po.POID
               AND ds.Stage = 'Approved'
               AND ds.IsActive = 1
            WHERE l.InventoryLogID = @DocumentID
            ORDER BY po.POID DESC, ds.SignatureID DESC;
        END;
    END;

    /*  REPLENISHMENT_REQUEST (@DocumentID = RepFID):
           Requested -> fallback to OriginRequisition Requested
           Inventory -> fallback to latest RECEIVING_REPORT Received for this RepFID */
    IF @DocumentType = 'REPLENISHMENT_REQUEST'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Requested')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'REPLENISHMENT_REQUEST',
                @DocumentID,
                'Requested',
                N'Requested by',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                10
            FROM dbo.REPLENISHMENT_REQUESTS rr
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'REQUISITION'
               AND ds.DocumentID = rr.OriginRequisitionID
               AND ds.Stage = 'Requested'
               AND ds.IsActive = 1
            WHERE rr.RepFID = @DocumentID
              AND rr.OriginRequisitionID IS NOT NULL
            ORDER BY ds.SignatureID DESC;
        END;

        IF NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Inventory')
        BEGIN
            INSERT INTO @Result
            (
                SignatureID, DocumentType, DocumentID, Stage, StageLabel,
                SignerUserID, SignerName, SignerRole, SignatureImage,
                DocumentHash, SignedAt, IsHashValid, SortOrder
            )
            SELECT TOP (1)
                ds.SignatureID,
                'REPLENISHMENT_REQUEST',
                @DocumentID,
                'Inventory',
                N'Inventory staff',
                ds.SignerUserID,
                ds.SignerName,
                ds.SignerRole,
                ds.SignatureImage,
                ds.DocumentHash,
                ds.SignedAt,
                CAST(1 AS BIT),
                15
            FROM dbo.INVENTORY_LOGS l
            INNER JOIN dbo.DOCUMENT_SIGNATURES ds
                ON ds.DocumentType = 'RECEIVING_REPORT'
               AND ds.DocumentID = l.InventoryLogID
               AND ds.Stage = 'Received'
               AND ds.IsActive = 1
            WHERE l.ReferenceType = 'REPLENISHMENT'
              AND l.ReferenceID = @DocumentID
              AND l.TransactionType = 'Stock In'
            ORDER BY l.InventoryLogID DESC, ds.SignatureID DESC;
        END;
    END;

    /*  STOCK_CARD (@DocumentID = ItemID):
           Custodian -> fallback to latest RECEIVING_REPORT Received for this ItemID  */
    IF @DocumentType = 'STOCK_CARD'
       AND NOT EXISTS (SELECT 1 FROM @Result WHERE Stage = 'Custodian')
    BEGIN
        INSERT INTO @Result
        (
            SignatureID, DocumentType, DocumentID, Stage, StageLabel,
            SignerUserID, SignerName, SignerRole, SignatureImage,
            DocumentHash, SignedAt, IsHashValid, SortOrder
        )
        SELECT TOP (1)
            ds.SignatureID,
            'STOCK_CARD',
            @DocumentID,
            'Custodian',
            N'Inventory custodian',
            ds.SignerUserID,
            ds.SignerName,
            ds.SignerRole,
            ds.SignatureImage,
            ds.DocumentHash,
            ds.SignedAt,
            CAST(1 AS BIT),
            20
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.DOCUMENT_SIGNATURES ds
            ON ds.DocumentType = 'RECEIVING_REPORT'
           AND ds.DocumentID = l.InventoryLogID
           AND ds.Stage = 'Received'
           AND ds.IsActive = 1
        WHERE l.ItemID = @DocumentID
        ORDER BY l.InventoryLogID DESC, ds.SignatureID DESC;
    END;

    SELECT
        SignatureID,
        DocumentType,
        DocumentID,
        Stage,
        StageLabel,
        SignerUserID,
        SignerName,
        SignerRole,
        SignatureImage,
        DocumentHash,
        SignedAt,
        IsHashValid
    FROM @Result
    ORDER BY SortOrder, SignedAt;
END;
GO

CREATE   PROCEDURE dbo.usp_DocumentSignature_Revoke
    @ActorUserID INT,
    @SignatureID BIGINT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @DocType VARCHAR(40),
        @DocID INT,
        @Stage VARCHAR(40),
        @SignerUserID INT;

    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL
        THROW 50710, 'A revoke reason is required.', 1;

    /* Admin ra ang maka-revoke. Ang normal nga correction flow kay
       mo-supersede sa signature, dili mo-delete. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r
            ON r.RoleID = u.RoleID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND r.RoleName = N'Admin'
    )
        THROW 50711,
            'Only an Admin can revoke a stored signature.',
            1;

    SELECT
        @DocType = DocumentType,
        @DocID = DocumentID,
        @Stage = Stage,
        @SignerUserID = SignerUserID
    FROM dbo.DOCUMENT_SIGNATURES
    WHERE SignatureID = @SignatureID
      AND IsActive = 1;

    IF @DocType IS NULL
        THROW 50712, 'The active signature was not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.DOCUMENT_SIGNATURES
        SET IsActive = 0,
            RevokedAt = SYSDATETIME(),
            RevokedByUserID = @ActorUserID,
            RevokeReason = LTRIM(RTRIM(@Reason))
        WHERE SignatureID = @SignatureID
          AND IsActive = 1;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID,
            @SignerUserID,
            'DOCUMENT_SIGNATURE_REVOKED',
            CONCAT(
                'Revoked signature #', @SignatureID,
                ' on ', @DocType, ' #', @DocID,
                ' (', @Stage, '): ', LEFT(LTRIM(RTRIM(@Reason)), 250)
            )
        );

        COMMIT TRANSACTION;

        SELECT N'Signature revoked.' AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   4. GENERIC SIGN / REVOKE / GET / VERIFY
 */

CREATE   PROCEDURE dbo.usp_DocumentSignature_Sign
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT,
    @Stage VARCHAR(40),
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 0,
    /* Kung 0, walay result set. Gigamit sa wrappers aron dili
       mabalda ang ilang kaugalingong response shape. */
    @ReturnResult BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PermissionCodes VARCHAR(200),
        @StageLabel NVARCHAR(80),
        @RoleLabel NVARCHAR(80),
        @SignerName NVARCHAR(200),
        @SignerRole NVARCHAR(100),
        @DocumentHash CHAR(64),
        @EmptyHash CHAR(64),
        @Now DATETIME2(0) = SYSDATETIME(),
        @SignatureID BIGINT,
        @ExistingHash CHAR(64);

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm the signature checkbox before saving.',
            1;

    SELECT
        @PermissionCodes = PermissionCodes,
        @StageLabel = StageLabel,
        @RoleLabel = RoleLabel
    FROM dbo.DOCUMENT_SIGNATURE_STAGES
    WHERE DocumentType = @DocumentType
      AND Stage = @Stage
      AND IsActive = 1;

    IF @PermissionCodes IS NULL
        THROW 50700,
            'The requested signature stage is not configured.',
            1;

    /* Permission check: bisan unsa sa comma-separated codes. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND CHARINDEX(
                ',' + p.PermissionCode + ',',
                ',' + @PermissionCodes + ',') > 0
    )
        THROW 50701,
            'You do not have permission to sign this document stage.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50702, 'A signature is required.', 1;

    IF @SignatureImage NOT LIKE N'data:image/%'
        THROW 50703, 'The signature image is not valid.', 1;

    IF LEN(@SignatureImage) > 2000000
        THROW 50704, 'The signature image is too large.', 1;

    SELECT
        @SignerName = LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
        @SignerRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID;

    IF @SignerName IS NULL
        THROW 50705, 'The signer account could not be found.', 1;

    SET @DocumentHash = dbo.fn_DocumentSignatureHash(
        @DocumentType, @DocumentID);
    SET @EmptyHash = CONVERT(
        CHAR(64), HASHBYTES('SHA2_256', N''), 2);

    IF @DocumentHash = @EmptyHash
        THROW 50706,
            'The document could not be found for signing.',
            1;

    /* Record lock check. Para sa STOCK_CARD nga mo-usab ang balanse
       sa dagan sa panahon, kung nausab na ang snapshot hash, i-supersede
       ang daan nga stock card sign-off (preserved sa audit trail).
       Para sa tanang uban nga business documents, locked human mapirmahan. */
    SELECT @ExistingHash = ds.DocumentHash
    FROM dbo.DOCUMENT_SIGNATURES ds
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.Stage = @Stage
      AND ds.IsActive = 1;

    IF @ExistingHash IS NOT NULL
    BEGIN
        IF @DocumentType = 'STOCK_CARD' AND @ExistingHash <> @DocumentHash
        BEGIN
            UPDATE dbo.DOCUMENT_SIGNATURES
            SET IsActive = 0,
                RevokedAt = @Now,
                RevokedByUserID = @ActorUserID,
                RevokeReason = N'Superseded by updated stock card snapshot.'
            WHERE DocumentType = @DocumentType
              AND DocumentID = @DocumentID
              AND Stage = @Stage
              AND IsActive = 1;
        END
        ELSE
        BEGIN
            THROW 50707,
                'This document stage is already signed and locked. Use the correction flow or Admin revoke instead.',
                1;
        END
    END;

    INSERT INTO dbo.DOCUMENT_SIGNATURES
    (
        DocumentType, DocumentID, Stage, SignerUserID, SignerName,
        SignerRole, SignatureImage, DocumentHash, ConfirmationAccepted,
        SignedAt, IsActive
    )
    VALUES
    (
        @DocumentType, @DocumentID, @Stage, @ActorUserID, @SignerName,
        @SignerRole, @SignatureImage, @DocumentHash, 1, @Now, 1
    );

    SET @SignatureID = SCOPE_IDENTITY();

    INSERT INTO dbo.USER_AUDIT_LOGS
    (
        ActorUserID, TargetUserID, ActionType, Description
    )
    VALUES
    (
        @ActorUserID,
        @ActorUserID,
        'DOCUMENT_SIGNED',
        CONCAT(
            'Digitally signed ', @DocumentType, ' #', @DocumentID,
            ' (', @Stage, ') as ', @SignerRole,
            ' [hash ', LEFT(@DocumentHash, 12), '].'
        )
    );

    IF @ReturnResult = 1
    BEGIN
        SELECT
            @SignatureID AS SignatureID,
            @DocumentType AS DocumentType,
            @DocumentID AS DocumentID,
            @Stage AS Stage,
            @StageLabel AS StageLabel,
            @RoleLabel AS RoleLabel,
            @SignerName AS SignerName,
            @SignerRole AS SignerRole,
            @DocumentHash AS DocumentHash,
            @Now AS SignedAt,
            CAST(1 AS BIT) AS IsHashValid;
    END
END;
GO

/* 
   6. SIGNATURE AUDIT / VERIFY
 */

CREATE   PROCEDURE dbo.usp_DocumentSignature_Verify
    @ActorUserID INT,
    @DocumentType VARCHAR(40),
    @DocumentID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS
        WHERE UserID = @ActorUserID
          AND IsActive = 1
    )
        THROW 50720, 'Your session is no longer active.', 1;

    DECLARE @CurrentHash CHAR(64) =
        dbo.fn_DocumentSignatureHash(@DocumentType, @DocumentID);

    SELECT
        ds.SignatureID,
        ds.DocumentType,
        ds.DocumentID,
        ds.Stage,
        ds.SignerUserID,
        ds.SignerName,
        ds.SignerRole,
        ds.SignedAt,
        ds.DocumentHash,
        @CurrentHash AS CurrentHash,
        ds.ConfirmationAccepted,
        CASE
            WHEN ds.DocumentHash = @CurrentHash
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS IsHashValid
    FROM dbo.DOCUMENT_SIGNATURES ds
    WHERE ds.DocumentType = @DocumentType
      AND ds.DocumentID = @DocumentID
      AND ds.IsActive = 1
    ORDER BY ds.SignatureID;
END;
GO

CREATE   PROCEDURE dbo.usp_Email_GetRuntimeConfig
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN (N'purchasing.manage', N'requisitions.approve', N'settings.manage')
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

/* Kani nga procedure para makuha ang permission codes sa active user.
   Kini ang gigamit sa app para mag-gate sa mga button ug pages. */
CREATE   PROCEDURE dbo.usp_GetUserPermissions
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

/* ================================================================
   2. ADJUST STOCK â€” reorder check human sa commit
   ================================================================ */
CREATE   PROCEDURE dbo.usp_Inventory_AdjustStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityChange INT,
    @Remarks NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityChange = 0
        THROW 50312, 'The adjustment quantity cannot be zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.adjust'
    )
        THROW 50313, 'You do not have permission to adjust inventory stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50315, 'The item is inactive or was not found.', 1;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);

    IF @OnHand IS NULL
        THROW 50316, 'No stock record exists for this item yet.', 1;

    IF (@OnHand + @QuantityChange) < @Reserved
        THROW 50314, 'The adjustment would make the stock lower than the reserved quantity.', 1;

    UPDATE INVENTORY
    SET QuantityOnHand = QuantityOnHand + @QuantityChange, LastUpdated = SYSDATETIME()
    WHERE ItemID = @ItemID;

    DECLARE @AdjustmentLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Adjustment', @QuantityChange, @OnHand, @OnHand + @QuantityChange, 'ADJUSTMENT', 0,
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Inventory quantity manually adjusted.'), SYSDATETIME());

    SET @AdjustmentLogID = SCOPE_IDENTITY();
    UPDATE INVENTORY_LOGS
    SET ReferenceID = @AdjustmentLogID
    WHERE InventoryLogID = @AdjustmentLogID AND ReferenceID = 0;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ADJUSTED',
            CONCAT('Stock adjusted by ', @QuantityChange, ' for item ID ', @ItemID, '.'));

    COMMIT TRANSACTION;

    -- Diri na mo-gawas ang low-stock RepF kung ang adjustment nagpahinabo
    -- nga Available <= ReorderPoint. Ang pag-add og stock dili mo-trigger.
    EXEC dbo.usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;
END;
GO

CREATE   PROCEDURE dbo.usp_Inventory_CheckReorderPoint
    @ItemID INT,
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ReorderPoint INT = (SELECT ReorderPoint FROM ITEMS WHERE ItemID = @ItemID);
    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Available INT = @OnHand - @Reserved;

    IF @ReorderPoint IS NULL OR @Available > @ReorderPoint
        RETURN;

    -- Kini nga quantity kay ang kulang para mobalik sa reorder point.
    DECLARE @Needed INT = CASE WHEN @Available < 0 THEN @ReorderPoint ELSE (@ReorderPoint - @Available) END;

    -- Pending RepF nga wala pay PR ug wala pay nadawat: pwede pa i-adjust
    -- ang quantity kay wala pa may na-order.
    DECLARE @PendingRepFID INT;

    SELECT TOP (1) @PendingRepFID = rr.RepFID
    FROM dbo.REPLENISHMENT_REQUESTS rr
    WHERE rr.ItemID = @ItemID
      AND rr.Status = 'Pending'
      AND rr.QuantityReceived = 0
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID
      )
    ORDER BY rr.RepFID;

    IF @PendingRepFID IS NOT NULL
    BEGIN
        -- Pasaka lang kung mas dako ang kasamtangan nga gap.
        IF @Needed > 0
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET QuantityNeeded = CASE
                    WHEN QuantityNeeded < @Needed THEN @Needed
                    ELSE QuantityNeeded
                END
            WHERE RepFID = @PendingRepFID;

        RETURN;
    END;

    -- Kung naa nay Pending RepF nga naa nay PR o partially received,
    -- ayaw og himo og laing RepF kay ma-doble ang order.
    IF EXISTS (
        SELECT 1 FROM dbo.REPLENISHMENT_REQUESTS
        WHERE ItemID = @ItemID AND Status = 'Pending'
    )
        RETURN;

    IF @Needed <= 0
        RETURN;

    INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
    VALUES (@ItemID, @Needed, SYSDATETIME(), 'Pending');

    -- Kini nga alert kay para sa tanang users nga may inventory.view permission.
    INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'LOW_STOCK', 'Low stock alert',
           'The stock of an item reached its reorder point. A replenishment request was generated.',
           'ITEM', @ItemID, 0, SYSDATETIME()
    FROM USERS u
    INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';
END;
GO

/* ================================================================
   8. ITEM CREATE/UPDATE UPDATE - i-validate ang UoM batok sa
      master list (case-insensitive, active lang). Ang existing
      nga items kay dili ma-apil sa validation problem kay ang
      default collation kay case-insensitive.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_CreateItem
    @ActorUserID INT,
    @ItemCode VARCHAR(30) = NULL,
    @ItemName NVARCHAR(200),
    @CategoryID INT,
    @UnitOfMeasure NVARCHAR(40),
    @ReorderPoint INT,
    @UnitPrice DECIMAL(18,2),
    @InitialQuantity INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Kani nga block kay para sa auto-generation sa ItemCode kung wala gihatag.
    IF NULLIF(LTRIM(RTRIM(@ItemCode)), '') IS NULL
    BEGIN
        DECLARE @MaxNum INT = (
            SELECT MAX(TRY_CAST(SUBSTRING(ItemCode, 5, 10) AS INT))
            FROM ITEMS
            WHERE ItemCode LIKE 'ITM-[0-9]%'
        );

        DECLARE @Candidate VARCHAR(30) =
            'ITM-' + RIGHT('000' + CAST(ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)), 3);

        WHILE EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @Candidate)
        BEGIN
            SET @MaxNum = ISNULL(@MaxNum, 0) + 1;
            SET @Candidate = 'ITM-' + RIGHT('000' + CAST(@MaxNum AS VARCHAR(10)), 3);
        END;

        SET @ItemCode = @Candidate;
    END;

    IF NULLIF(LTRIM(RTRIM(@ItemName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@UnitOfMeasure)), '') IS NULL
        THROW 50302, 'Item name and unit of measure are required.', 1;

    IF @ReorderPoint < 0 OR @UnitPrice < 0 OR @InitialQuantity < 0
        THROW 50303, 'Reorder point, unit price, and quantity cannot be negative.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.create'
    )
        THROW 50304, 'You do not have permission to create inventory items.', 1;

    IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = @CategoryID)
        THROW 50305, 'The selected category is not valid.', 1;

    -- Kani nga check kay para masiguro nga gikan sa master list ang UoM.
    IF NOT EXISTS (
        SELECT 1 FROM UNIT_OF_MEASURES
        WHERE UomName = @UnitOfMeasure COLLATE DATABASE_DEFAULT AND IsActive = 1
    )
        THROW 50370, 'The unit of measure must be selected from the unit of measures list.', 1;

    IF EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @ItemCode)
        THROW 50306, 'The item code is already used by another item.', 1;

    BEGIN TRANSACTION;

    INSERT INTO ITEMS (ItemCode, ItemName, CategoryID, UnitOfMeasure, ReorderPoint, UnitPrice, IsActive)
    VALUES (@ItemCode, @ItemName, @CategoryID, @UnitOfMeasure, @ReorderPoint, @UnitPrice, 1);

    DECLARE @NewItemID INT = SCOPE_IDENTITY();

    INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved)
    VALUES (@NewItemID, @InitialQuantity, 0);

    -- Kani nga log kay para sa initial stock sa bag-ong item.
    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, Remarks, TransactionDate)
    VALUES (@NewItemID, @ActorUserID, 'Stock In', @InitialQuantity, 0, @InitialQuantity, 'INITIAL',
            N'Initial inventory setup.', SYSDATETIME());

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ITEM_CREATED',
            CONCAT('Item ', @ItemCode, ' created with initial stock ', @InitialQuantity, '.'));

    COMMIT TRANSACTION;

    -- Kani nga result kay para makita sa frontend ang generated code.
    SELECT @NewItemID AS ItemID, @ItemCode AS ItemCode;
END;
GO

/* ================================================================
   1. ITEM LIST â€” tanang items uban ang live stock balance.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetAll
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50300, 'You do not have permission to view inventory.', 1;

    SELECT i.ItemID, i.ItemCode, i.ItemName, i.CategoryID, c.CategoryName,
           i.UnitOfMeasure, i.ReorderPoint, i.UnitPrice, i.IsActive,
           inv.QuantityOnHand, inv.QuantityReserved,
           (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable,
           CAST(CASE WHEN (inv.QuantityOnHand - inv.QuantityReserved) <= i.ReorderPoint
                THEN 1 ELSE 0 END AS BIT) AS IsLowStock
    FROM ITEMS i
    INNER JOIN CATEGORIES c ON c.CategoryID = i.CategoryID
    INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
    ORDER BY i.IsActive DESC, i.ItemName;
END;
GO

/* ================================================================
   2. CATEGORIES â€” para sa item form dropdown.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetCategories
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga check kay para makita ra sa settings.manage O inventory.view.
    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.view'
    )
       AND NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50301, 'You do not have permission to view categories.', 1;

    SELECT c.CategoryID, c.CategoryName, c.IsActive,
           (SELECT COUNT(*) FROM ITEMS i WHERE i.CategoryID = c.CategoryID) AS ItemCount
    FROM CATEGORIES c
    ORDER BY c.CategoryName;
END;
GO

/*
   7. LOG DISPLAY â€” i-reuse ang usp_Inventory_GetLogs nga may
      dugang nga AR-#### branch para sa delivery movements
      (display metadata ra, walay baliton nga transaction).
*/
CREATE   PROCEDURE dbo.usp_Inventory_GetLogs
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50324, 'You do not have permission to view inventory logs.', 1;

    SELECT TOP (100) l.InventoryLogID, i.ItemName, i.ItemCode, l.TransactionType,
           l.QuantityChange, l.PreviousQuantity, l.NewQuantity,
           l.ReferenceType, l.ReferenceID, l.Remarks, l.TransactionDate,
           CONCAT(u.FirstName, ' ', u.LastName) AS UserName,
           CASE
               WHEN l.ReferenceType = 'REQUISITION' AND l.ReferenceID IS NOT NULL
                   THEN 'RF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'DELIVERY' AND l.ReferenceID IS NOT NULL
                   THEN 'AR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                   THEN 'RefP-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'RECEIVING' AND l.ReferenceID IS NOT NULL
                   THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType IN ('MANUAL', 'ADJUSTMENT') AND l.TransactionType = 'Adjustment'
                   THEN 'ADJ-' + RIGHT('0000' + CAST(ISNULL(l.ReferenceID, l.InventoryLogID) AS VARCHAR(10)), 4)
               WHEN l.ReferenceType IN ('SEED', 'INITIAL') AND l.ReferenceID IS NOT NULL
                   THEN 'ADJ-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               ELSE NULL
           END AS ReferenceDisplay,
           CASE
               WHEN l.ReferenceType IN ('SEED', 'INITIAL') THEN 'Initial Stock'
               WHEN l.TransactionType IN ('Reservation', 'Release', 'Stock Out') THEN 'Issuance'
               WHEN l.TransactionType = 'Stock In' THEN 'Receiving'
               WHEN l.TransactionType = 'Adjustment' THEN 'Adjustment'
               ELSE l.TransactionType
           END AS SourceDisplay
    FROM INVENTORY_LOGS l
    INNER JOIN ITEMS i ON i.ItemID = l.ItemID
    LEFT JOIN USERS u ON u.UserID = l.UserID
    ORDER BY l.TransactionDate DESC, l.InventoryLogID DESC;
END;
GO

/* ================================================================
   2b. NEXT ITEM CODE â€” auto-generate nga ItemCode para sa form.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetNextItemCode
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
          AND p.PermissionCode = N'inventory.create'
    )
        THROW 50330, 'You do not have permission to create inventory items.', 1;

    -- Kani nga block kay mo-generate sa sunod nga ITM-### code.
    DECLARE @MaxNum INT = (
        SELECT MAX(TRY_CAST(SUBSTRING(ItemCode, 5, 10) AS INT))
        FROM ITEMS
        WHERE ItemCode LIKE 'ITM-[0-9]%'
    );

    DECLARE @Candidate VARCHAR(30) =
        'ITM-' + RIGHT('000' + CAST(ISNULL(@MaxNum, 0) + 1 AS VARCHAR(10)), 3);

    WHILE EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @Candidate)
    BEGIN
        SET @MaxNum = ISNULL(@MaxNum, 0) + 1;
        SET @Candidate = 'ITM-' + RIGHT('000' + CAST(@MaxNum AS VARCHAR(10)), 3);
    END;

    SELECT @Candidate AS NextItemCode;
END;
GO

/* ================================================================
   13. OVERVIEW â€” usa ra ka call nga magdala sa tanang page data
      (items + categories + reservations + RepFs + logs) aron
      dili na magkagawas ang lima ka database connections matag
      pag-load sa Inventory page.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetOverview
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50329, 'You do not have permission to view inventory.', 1;

    -- Kani nga resultset kay para sa items nga may live stock balance.
    EXEC usp_Inventory_GetAll @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa category dropdown.
    EXEC usp_Inventory_GetCategories @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa active reservations.
    EXEC usp_Inventory_GetReservations @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa replenishment requests.
    EXEC usp_Inventory_GetRepFs @ActorUserID = @ActorUserID;

    -- Kani nga resultset kay para sa recent stock movements.
    EXEC usp_Inventory_GetLogs @ActorUserID = @ActorUserID;
END;
GO

/* ================================================================
   12. PANEL SUMMARY â€” para sa dashboard inventory panel.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetPanel
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50327, 'You do not have permission to view the inventory panel.', 1;

    SELECT
        (SELECT COUNT(*) FROM ITEMS WHERE IsActive = 1) AS TotalItems,

        (SELECT COUNT(*)
         FROM ITEMS i
         INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
         WHERE i.IsActive = 1
           AND (inv.QuantityOnHand - inv.QuantityReserved) <= i.ReorderPoint) AS LowStockItems,

        (SELECT ISNULL(SUM(QuantityReserved), 0) FROM INVENTORY) AS ReservedUnits,

        (SELECT COUNT(*) FROM REPLENISHMENT_REQUESTS WHERE Status = 'Pending') AS PendingRepFs,

        (SELECT COUNT(*)
         FROM INVENTORY_RESERVATIONS r
         INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
         WHERE r.Status = 'Active' AND rd.Status = 'Partially Fulfilled') AS PartialReservations,

        (SELECT COUNT(*) FROM INVENTORY_LOGS
         WHERE TransactionDate >= DATEADD(DAY, -1, SYSDATETIME())) AS RecentMovements;
END;
GO

/*
   5. INVENTORY RepF LIST â€” re-emit gikan sa V003 nga may
      OriginRequisitionID (Requisition # column).
*/
CREATE   PROCEDURE dbo.usp_Inventory_GetRepFs
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50326, 'You do not have permission to view replenishment requests.', 1;

    SELECT f.RepFID, f.ItemID, i.ItemName, i.ItemCode, f.QuantityNeeded,
           f.DateGenerated, f.Status, f.OriginRequisitionID
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    ORDER BY CASE WHEN f.Status = 'Pending' THEN 0 ELSE 1 END, f.DateGenerated DESC;
END;
GO

/* ============================================================
   7. REPLENISHMENT REQUEST PRINT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Inventory_GetReplenishmentPrint
    @ActorUserID INT,
    @RepFID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'inventory.view'
    )
        THROW 50607,
            'You do not have permission to print replenishment requests.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REPLENISHMENT_REQUESTS
        WHERE RepFID = @RepFID
    )
        RETURN;

    SELECT
        rr.RepFID,
        rr.ItemID,
        i.ItemCode,
        i.ItemName,
        cat.CategoryName,
        i.UnitOfMeasure,
        i.ReorderPoint,
        rr.QuantityNeeded,
        rr.QuantityReceived,
        rr.QuantityNeeded - rr.QuantityReceived AS RemainingQuantity,
        rr.DateGenerated,
        rr.Status,
        rr.OriginRequisitionID,
        LTRIM(RTRIM(CONCAT(
            originRequestor.FirstName, ' ', originRequestor.LastName
        ))) AS OriginRequestorName,
        ISNULL(inv.QuantityOnHand, 0) AS QuantityOnHand,
        ISNULL(inv.QuantityReserved, 0) AS QuantityReserved,
        ISNULL(
            inv.QuantityOnHand - inv.QuantityReserved, 0
        ) AS QuantityAvailable,
        po.POID,
        po.POStatus,
        po.SupplierName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    LEFT JOIN dbo.CATEGORIES cat
        ON cat.CategoryID = i.CategoryID
    LEFT JOIN dbo.INVENTORY inv
        ON inv.ItemID = rr.ItemID
    LEFT JOIN dbo.REQUISITIONS r
        ON r.RequisitionID = rr.OriginRequisitionID
    LEFT JOIN dbo.USERS originRequestor
        ON originRequestor.UserID = r.RequestorUserID
    OUTER APPLY
    (
        SELECT TOP (1)
            po.POID,
            po.Status AS POStatus,
            s.SupplierName
        FROM dbo.PURCHASE_REQUESTS pr
        INNER JOIN dbo.PURCHASE_ORDERS po
            ON po.PRID = pr.PRID
        INNER JOIN dbo.SUPPLIERS s
            ON s.SupplierID = po.SupplierID
        WHERE pr.RepFID = rr.RepFID
        ORDER BY po.POID DESC
    ) po
    WHERE rr.RepFID = @RepFID;
END;
GO

/* ================================================================
   10. RESERVATIONS â€” mga waiting ug reserved nga requests.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_GetReservations
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
          AND p.PermissionCode = N'inventory.view'
    )
        THROW 50325, 'You do not have permission to view reservations.', 1;

    SELECT r.ReservationID, r.RequisitionDetailID, rd.RequisitionID,
           i.ItemName, i.ItemCode, r.QuantityReserved, r.ReservationDate,
           r.Status,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName
    FROM INVENTORY_RESERVATIONS r
    INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
    INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
    INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
    INNER JOIN USERS reqUser ON reqUser.UserID = req.RequestorUserID
    ORDER BY r.ReservationDate DESC;
END;
GO

/* ============================================================
   4. STOCK CARD PRINT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Inventory_GetStockCard
    @ActorUserID INT,
    @ItemID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'inventory.view'
    )
        THROW 50604,
            'You do not have permission to print stock cards.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.ITEMS
        WHERE ItemID = @ItemID
    )
        RETURN;

    /* Result set 1: item header. */
    SELECT
        i.ItemID,
        i.ItemCode,
        i.ItemName,
        cat.CategoryName,
        i.UnitOfMeasure,
        i.ReorderPoint,
        i.UnitPrice,
        i.IsActive,
        ISNULL(inv.QuantityOnHand, 0) AS QuantityOnHand,
        ISNULL(inv.QuantityReserved, 0) AS QuantityReserved,
        ISNULL(
            inv.QuantityOnHand - inv.QuantityReserved, 0
        ) AS QuantityAvailable,
        inv.LastUpdated,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline
    FROM dbo.ITEMS i
    LEFT JOIN dbo.CATEGORIES cat
        ON cat.CategoryID = i.CategoryID
    LEFT JOIN dbo.INVENTORY inv
        ON inv.ItemID = i.ItemID
    WHERE i.ItemID = @ItemID;

    /* Result set 2: running stock movements (oldest first). */
    SELECT
        l.InventoryLogID,
        l.TransactionDate,
        l.TransactionType,
        l.QuantityChange,
        l.PreviousQuantity,
        l.NewQuantity,
        CASE l.ReferenceType
            WHEN 'RECEIVING' THEN
                'RR-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN 'REPLENISHMENT' THEN
                'RefP-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN 'DELIVERY' THEN
                'AR-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN 'REQUISITION' THEN
                'RF-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN 'ADJUSTMENT' THEN
                'ADJ-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN 'PURCHASE' THEN
                'PO-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            ELSE NULL
        END AS ReferenceDisplay,
        CASE l.ReferenceType
            WHEN 'RECEIVING' THEN 'Receiving'
            WHEN 'REPLENISHMENT' THEN 'Replenishment'
            WHEN 'DELIVERY' THEN 'Issuance'
            WHEN 'REQUISITION' THEN 'Requisition'
            WHEN 'ADJUSTMENT' THEN 'Adjustment'
            WHEN 'PURCHASE' THEN 'Purchase'
            ELSE 'System'
        END AS SourceDisplay,
        LTRIM(RTRIM(CONCAT(
            u.FirstName, ' ', u.LastName
        ))) AS UserName,
        l.Remarks
    FROM dbo.INVENTORY_LOGS l
    LEFT JOIN dbo.USERS u
        ON u.UserID = l.UserID
    WHERE l.ItemID = @ItemID
    ORDER BY l.TransactionDate, l.InventoryLogID;
END;
GO

/* ============================================================
   4. ISSUE STOCK SHORTAGE â€” REQUISITION TARGET FOR REQUESTOR
      & PURCHASING/INVENTORY TARGET FOR REPLENISHMENT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Inventory_IssueStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityRequested INT,
    @RequisitionID INT = NULL,
    @EstimatedRestockDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityRequested IS NULL OR @QuantityRequested <= 0
        THROW 50315, 'The requested quantity must be greater than zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND (
              p.PermissionCode = N'inventory.update'
              OR (@RequisitionID IS NOT NULL AND p.PermissionCode = N'requisitions.approve')
          )
    )
        THROW 50316, 'You do not have permission to issue stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50317, 'The item is inactive or was not found.', 1;

    DECLARE @RequestorUserID INT = @ActorUserID;
    DECLARE @RequisitionDetailID INT = NULL;
    DECLARE @RemainingQty INT = @QuantityRequested;

    IF @RequisitionID IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.REQUISITIONS WHERE RequisitionID = @RequisitionID AND Status = 'Approved')
            THROW 50318, 'Only an approved requisition can be issued stock.', 1;

        SELECT @RequestorUserID = r.RequestorUserID
        FROM dbo.REQUISITIONS r
        WHERE r.RequisitionID = @RequisitionID;

        SELECT TOP (1) @RequisitionDetailID = rd.RequisitionDetailID,
                       @RemainingQty = ISNULL(rd.QuantityApproved, rd.QuantityRequested)
        FROM dbo.REQUISITION_DETAILS rd
        WHERE rd.RequisitionID = @RequisitionID
          AND rd.ItemID = @ItemID
          AND rd.Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        IF @RequisitionDetailID IS NULL
            THROW 50319, 'The requisition does not include this item or it is already fulfilled.', 1;

        DECLARE @AlreadyReserved INT = ISNULL((
            SELECT SUM(r.QuantityReserved)
            FROM dbo.INVENTORY_RESERVATIONS r
            WHERE r.RequisitionDetailID = @RequisitionDetailID AND r.Status = 'Active'
        ), 0);

        SET @RemainingQty = @RemainingQty - @AlreadyReserved;

        IF @RemainingQty <= 0
            THROW 50328, 'This requisition item is already fully reserved.', 1;
    END;

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM dbo.INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM dbo.INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Available INT = @OnHand - @Reserved;

    IF @Available >= @RemainingQty
    BEGIN
        UPDATE dbo.INVENTORY
        SET QuantityReserved = QuantityReserved + @RemainingQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @RemainingQty, @Reserved, @Reserved + @RemainingQty,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CASE WHEN @RequisitionID IS NULL
                     THEN CONCAT('Stock reserved for issuance: ', @RemainingQty, ' unit(s).')
                     ELSE N'Stock reserved for approved requisition.'
                END, SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            UPDATE dbo.REQUISITION_DETAILS
            SET Status = 'Approved'
            WHERE RequisitionDetailID = @RequisitionDetailID;

            INSERT INTO dbo.INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @RemainingQty, SYSDATETIME(), 'Active');
        END;

        INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_RESERVED', 'Stock reserved',
                'Your requested item has been reserved and is ready for delivery.',
                'REQUISITION', @RequisitionID, 0, SYSDATETIME());

        COMMIT TRANSACTION;

        EXEC dbo.usp_Inventory_CheckReorderPoint @ItemID, @ActorUserID;

        SELECT 'Reserved' AS Outcome, @RemainingQty AS ReservedQuantity, 0 AS ShortageQuantity, NULL AS RepFID;
        RETURN;
    END;

    DECLARE @ShortageQty INT = @RemainingQty - @Available;

    IF @Available > 0
    BEGIN
        UPDATE dbo.INVENTORY
        SET QuantityReserved = QuantityReserved + @Available, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO dbo.INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES (@ItemID, @ActorUserID, 'Reservation', @Available, @Reserved, @Reserved + @Available,
                CASE WHEN @RequisitionID IS NULL THEN 'MANUAL' ELSE 'REQUISITION' END, @RequisitionID,
                CONCAT('Partial reservation: only ', @Available, ' of ', @RemainingQty,
                       ' unit(s) available. Replenishment request generated.'), SYSDATETIME());

        IF @RequisitionDetailID IS NOT NULL
        BEGIN
            INSERT INTO dbo.INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@RequisitionDetailID, @Available, SYSDATETIME(), 'Active');
        END;
    END;

    DECLARE @NewRepFID INT = NULL;

    IF @ShortageQty > 0
    BEGIN
        SELECT TOP (1) @NewRepFID = rr.RepFID
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.ItemID = @ItemID
          AND rr.Status = 'Pending'
          AND (rr.OriginRequisitionID IS NULL OR rr.OriginRequisitionID = @RequisitionID)
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PURCHASE_REQUESTS pr WHERE pr.RepFID = rr.RepFID
          )
        ORDER BY rr.RepFID;

        IF @NewRepFID IS NOT NULL
        BEGIN
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET QuantityNeeded = QuantityNeeded + @ShortageQty,
                OriginRequisitionID = COALESCE(OriginRequisitionID, @RequisitionID)
            WHERE RepFID = @NewRepFID;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status, OriginRequisitionID)
            VALUES (@ItemID, @ShortageQty, SYSDATETIME(), 'Pending', @RequisitionID);
            SET @NewRepFID = SCOPE_IDENTITY();
        END;
    END;

    IF @RequisitionDetailID IS NOT NULL
    BEGIN
        UPDATE dbo.REQUISITION_DETAILS
        SET Status = CASE WHEN @Available > 0 THEN 'Partially Fulfilled' ELSE 'Pending' END
        WHERE RequisitionDetailID = @RequisitionDetailID;
    END;

    DECLARE @RestockDays INT = ISNULL(
        NULLIF((SELECT TOP (1) TRY_CONVERT(INT, SettingValue) FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'DefaultRestockDays'), 0),
        7);
    DECLARE @Estimate DATE = COALESCE(@EstimatedRestockDate, DATEADD(DAY, @RestockDays, CAST(SYSDATETIME() AS DATE)));

    /* Requestor's shortage notice links directly to their Requisition so clicking highlights their RF row. */
    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    VALUES (@RequestorUserID, 'STOCK_SHORTAGE', 'Stock shortage on request',
            CONCAT(
                CASE WHEN @RequisitionID IS NOT NULL
                     THEN CONCAT('Requisition #', @RequisitionID, ': ')
                     ELSE ''
                END,
                'Only part of your request is available. A replenishment request was generated. Estimated restock date: ',
                CONVERT(VARCHAR(10), @Estimate, 120), '.'),
            CASE WHEN @RequisitionID IS NOT NULL THEN 'REQUISITION' ELSE 'REPLENISHMENT_REQUEST' END,
            COALESCE(@RequisitionID, @NewRepFID),
            0, SYSDATETIME());

    /* Replenishment alert links to RepF for Purchasing Staff and Inventory Staff. */
    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, 'STOCK_SHORTAGE', 'Stock shortage needs replenishment',
           CONCAT('A shortage of ', @ShortageQty, ' unit(s) was noted on an item (',
                  i.ItemName, '). A replenishment request was generated.'),
           'REPLENISHMENT_REQUEST', @NewRepFID, 0, SYSDATETIME()
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    INNER JOIN dbo.ITEMS i ON i.ItemID = @ItemID
    WHERE u.IsActive = 1
      AND p.PermissionCode IN (N'purchasing.view', N'inventory.update')
      AND u.UserID <> @RequestorUserID;

    COMMIT TRANSACTION;
    SELECT 'Shortage' AS Outcome, @Available AS ReservedQuantity, @ShortageQty AS ShortageQuantity, @NewRepFID AS RepFID;
END;
GO

CREATE   PROCEDURE dbo.usp_Inventory_ReceiveStock
    @ActorUserID INT,
    @ItemID INT,
    @QuantityReceived INT,
    @RepFID INT = NULL,
    @Remarks NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuantityReceived IS NULL OR @QuantityReceived <= 0
        THROW 50320, 'The received quantity must be greater than zero.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'receiving.manage'
    )
        THROW 50321, 'You do not have permission to record received stock.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID AND IsActive = 1)
        THROW 50322, 'The item is inactive or was not found.', 1;

    IF @RepFID IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE RepFID = @RepFID AND ItemID = @ItemID)
        THROW 50323, 'The replenishment request does not match this item.', 1;

    -- Kani nga guard kay para sa partial receive: dili molapas ang
    -- nadawat sa remaining needed sa RepF (over-receive cap).
    IF @RepFID IS NOT NULL
    BEGIN
        DECLARE @RepFRemaining INT = (
            SELECT f.QuantityNeeded - f.QuantityReceived
            FROM REPLENISHMENT_REQUESTS f
            WHERE f.RepFID = @RepFID AND f.Status = N'Pending'
        );

        IF @RepFRemaining IS NULL
            THROW 50410, 'The replenishment request is no longer pending.', 1;

        IF @QuantityReceived > @RepFRemaining
            THROW 50411, 'The received quantity cannot exceed the remaining needed quantity for this replenishment request.', 1;
    END

    BEGIN TRANSACTION;

    DECLARE @OnHand INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @Reserved INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);

    -- Kani nga step kay para ma-record ang RIM ug mo-increase ang balance.
    UPDATE INVENTORY
    SET QuantityOnHand = QuantityOnHand + @QuantityReceived, LastUpdated = SYSDATETIME()
    WHERE ItemID = @ItemID;

    -- Kani nga insert kay para sa receiving log. Kung wala nga RepF,
    -- ang log row mismo ang Receiving Record (RR-####) â€” self-referencing.
    DECLARE @ReceiveLogID INT;

    INSERT INTO INVENTORY_LOGS (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
    VALUES (@ItemID, @ActorUserID, 'Stock In', @QuantityReceived, @OnHand, @OnHand + @QuantityReceived,
            CASE WHEN @RepFID IS NULL THEN 'RECEIVING' ELSE 'REPLENISHMENT' END, ISNULL(@RepFID, 0),
            ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), ''), N'Items received and added to inventory.'), SYSDATETIME());

    -- Kani nga update kay para mahimong RR-#### ang reference niini.
    SET @ReceiveLogID = SCOPE_IDENTITY();
    UPDATE INVENTORY_LOGS
    SET ReferenceID = @ReceiveLogID
    WHERE InventoryLogID = @ReceiveLogID AND ReferenceID = 0;

    -- Kani nga update kay para sa PARTIAL receive: ang RepF mo-pabilin
    -- Pending hangtod ma-kompleto ang QuantityNeeded, ug naa na'y
    -- QuantityReceived tracking.
    IF @RepFID IS NOT NULL
    BEGIN
        UPDATE REPLENISHMENT_REQUESTS
        SET QuantityReceived = QuantityReceived + @QuantityReceived,
            Status = CASE
                WHEN (QuantityReceived + @QuantityReceived) >= QuantityNeeded THEN 'Processed'
                ELSE 'Pending'
            END
        WHERE RepFID = @RepFID AND Status = 'Pending';
    END

    -- Kani nga allocation loop kay para sa mga waiting reservations sa item.
    -- Kani nga origin kay ang requisition nga hinungdan sa RepF (priority).
    DECLARE @OriginRequisitionID INT = CASE WHEN @RepFID IS NULL THEN NULL ELSE
        (SELECT OriginRequisitionID FROM REPLENISHMENT_REQUESTS WHERE RepFID = @RepFID) END;

    DECLARE @ReservationID INT;
    DECLARE @ReservationDetailID INT;
    DECLARE @ReservationRequisitionID INT;
    DECLARE @ShortageQty INT;
    DECLARE @RequestorUserID INT;

    -- Kani nga cursor kay duha ka source:
    --   (a) existing Active reservations nga kulang pa (partial), ug
    --   (b) Approved requisition details nga Pending ug WALAY Active
    --       reservation (zero-stock case; ang CK_RESERVATIONS_Quantity
    --       wala motugot og 0, mao nga wala'y row ang gihimo sa Issue).
    DECLARE waitingCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT w.ReservationID, w.RequisitionDetailID, w.RequisitionID,
               w.QuantityNeeded, w.RequestorUserID
        FROM (
        SELECT r.ReservationID, r.RequisitionDetailID, rd.RequisitionID,
               (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) AS QuantityNeeded,
               req.RequestorUserID, req.RequestDate AS SortDate,
               CASE WHEN rd.RequisitionID = @OriginRequisitionID THEN 0 ELSE 1 END AS PriorityRank
        FROM INVENTORY_RESERVATIONS r
        INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionDetailID = r.RequisitionDetailID
        INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
        INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
        WHERE i.ItemID = @ItemID
          AND r.Status = 'Active'
          AND (ISNULL(rd.QuantityApproved, rd.QuantityRequested) - r.QuantityReserved) > 0
        UNION ALL
        SELECT CAST(NULL AS INT), rd.RequisitionDetailID, rd.RequisitionID,
               ISNULL(rd.QuantityApproved, rd.QuantityRequested),
               req.RequestorUserID, req.RequestDate,
               CASE WHEN rd.RequisitionID = @OriginRequisitionID THEN 0 ELSE 1 END
        FROM REQUISITION_DETAILS rd
        INNER JOIN REQUISITIONS req ON req.RequisitionID = rd.RequisitionID
        WHERE rd.ItemID = @ItemID
          AND req.Status = 'Approved'
          AND rd.Status = 'Pending'
          AND NOT EXISTS (SELECT 1 FROM INVENTORY_RESERVATIONS x
                          WHERE x.RequisitionDetailID = rd.RequisitionDetailID
                            AND x.Status = 'Active')
        ) AS w
        ORDER BY w.PriorityRank, w.SortDate, w.RequisitionDetailID;

    OPEN waitingCursor;
    FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @AvailableNow INT =
            (SELECT (QuantityOnHand - QuantityReserved) FROM INVENTORY WHERE ItemID = @ItemID);

        IF @AvailableNow <= 0
            BREAK;

        DECLARE @AllocateQty INT = CASE WHEN @AvailableNow < @ShortageQty THEN @AvailableNow ELSE @ShortageQty END;

        -- Kani nga branch: bag-ong reservation row kung wala pa (zero-stock
        -- case), kung naa na, i-dugang lang ang QuantityReserved.
        IF @ReservationID IS NULL
            INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, ReservationDate, Status)
            VALUES (@ReservationDetailID, @AllocateQty, SYSDATETIME(), 'Active');
        ELSE
            UPDATE INVENTORY_RESERVATIONS
            SET QuantityReserved = QuantityReserved + @AllocateQty
            WHERE ReservationID = @ReservationID;

        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved + @AllocateQty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        -- Kani nga update kay para sa detail status: approved kung kompleto na.
        UPDATE REQUISITION_DETAILS
        SET Status = CASE WHEN (@ShortageQty - @AllocateQty) = 0 THEN 'Approved' ELSE 'Partially Fulfilled' END
        WHERE RequisitionDetailID = @ReservationDetailID;

        -- Kani nga notification kay para sa requester: allocated ug ready
        -- for delivery. Ang requisition ID kay apil na sa message para
        -- klaro kung asa nga request gi-allocate ang nadawat nga stock.
        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        VALUES (@RequestorUserID, 'STOCK_ALLOCATED', 'Stock allocated to your request',
                CONCAT('Received stock was allocated to requisition #', @ReservationRequisitionID,
                       ' (', @AllocateQty, ' unit(s)). It is ready for delivery.'),
                'REQUISITION', @ReservationRequisitionID, 0, SYSDATETIME());

        FETCH NEXT FROM waitingCursor INTO @ReservationID, @ReservationDetailID, @ReservationRequisitionID, @ShortageQty, @RequestorUserID;
    END

    CLOSE waitingCursor;
    DEALLOCATE waitingCursor;

    COMMIT TRANSACTION;

    -- Kani nga reorder check kay gimana sa linya aron naka-commit na ang allocation.
    DECLARE @OnHandFinal INT = (SELECT QuantityOnHand FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @ReservedFinal INT = (SELECT QuantityReserved FROM INVENTORY WHERE ItemID = @ItemID);
    DECLARE @AvailableFinal INT = @OnHandFinal - @ReservedFinal;
    DECLARE @ReorderPoint INT = (SELECT ReorderPoint FROM ITEMS WHERE ItemID = @ItemID);

    IF @AvailableFinal <= @ReorderPoint
       AND (@ReorderPoint - @AvailableFinal) > 0
       AND NOT EXISTS (SELECT 1 FROM REPLENISHMENT_REQUESTS WHERE ItemID = @ItemID AND Status = 'Pending')
    BEGIN
        INSERT INTO REPLENISHMENT_REQUESTS (ItemID, QuantityNeeded, DateGenerated, Status)
        VALUES (@ItemID, (@ReorderPoint - @AvailableFinal), SYSDATETIME(), 'Pending');

        INSERT INTO NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT u.UserID, 'LOW_STOCK', 'Low stock alert',
               'The stock of an item reached its reorder point. A replenishment request was generated.',
               'ITEM', @ItemID, 0, SYSDATETIME()
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1 AND p.PermissionCode = N'inventory.view';
    END
END;
GO

CREATE   PROCEDURE usp_Inventory_ReleaseStock
    @ReservationID INT,
    @UserID INT,
    @NewStatus VARCHAR(30) = 'Released'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @NewStatus NOT IN ('Released', 'Cancelled')
        THROW 50110, 'The status must be either Released or Cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @DetailID INT, @Qty INT, @ItemID INT, @OnHand INT;
        SELECT @DetailID = r.RequisitionDetailID, @Qty = r.QuantityReserved
        FROM INVENTORY_RESERVATIONS r WITH (UPDLOCK, HOLDLOCK)
        WHERE r.ReservationID = @ReservationID AND r.Status = 'Active';

        IF @DetailID IS NULL
            THROW 50111, 'The active reservation could not be found.', 1;

        SELECT @ItemID = ItemID
        FROM REQUISITION_DETAILS
        WHERE RequisitionDetailID = @DetailID;

        SELECT @OnHand = QuantityOnHand
        FROM INVENTORY WITH (UPDLOCK, HOLDLOCK)
        WHERE ItemID = @ItemID AND QuantityReserved >= @Qty;

        IF @OnHand IS NULL
            THROW 50112, 'The reserved quantity in the inventory is incorrect.', 1;

        UPDATE INVENTORY
        SET QuantityReserved = QuantityReserved - @Qty, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        UPDATE INVENTORY_RESERVATIONS
        SET Status = @NewStatus
        WHERE ReservationID = @ReservationID AND Status = 'Active';

        INSERT INTO INVENTORY_LOGS
            (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
        VALUES
            (@ItemID, @UserID, 'Release', 0, @OnHand, @OnHand, 'Reservation', @ReservationID,
             CONCAT('This reservation was-', @NewStatus, '.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE usp_Inventory_ReserveStock
    @RequisitionDetailID INT,
    @Quantity INT,
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Quantity <= 0
        THROW 50100, 'The quantity must be greater than zero.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ItemID INT, @Previous INT, @Available INT, @NewReserved INT;
        SELECT @ItemID = rd.ItemID
        FROM REQUISITION_DETAILS rd WITH (UPDLOCK, HOLDLOCK)
        WHERE rd.RequisitionDetailID = @RequisitionDetailID
          AND rd.Status IN ('Approved', 'Partially Fulfilled');

        IF @ItemID IS NULL
            THROW 50101, 'The approved requisition details could not be found.', 1;

        SELECT @Previous = QuantityOnHand,
               @Available = QuantityAvailable,
               @NewReserved = QuantityReserved + @Quantity
        FROM INVENTORY WITH (UPDLOCK, HOLDLOCK)
        WHERE ItemID = @ItemID;

        IF @Available IS NULL
            THROW 50102, 'There is no inventory record for this item yet.', 1;

        IF @Available < @Quantity
            THROW 50103, 'The available stock is insufficient to reserve.', 1;

        UPDATE INVENTORY
        SET QuantityReserved = @NewReserved, LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, Status)
        VALUES (@RequisitionDetailID, @Quantity, 'Active');

        INSERT INTO INVENTORY_LOGS
            (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
        VALUES
            (@ItemID, @UserID, 'Reservation', 0, @Previous, @Previous, 'RequisitionDetail', @RequisitionDetailID,
             CONCAT('Kani nga reservation kay ', @Quantity, ' ka item.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ================================================================
   2c. CATEGORY SAVE â€” para sa Settings module: create o rename
      ug category, ug toggle sa active state.
   ================================================================ */
CREATE   PROCEDURE usp_Inventory_SaveCategory
    @ActorUserID INT,
    @CategoryID INT = NULL,
    @CategoryName NVARCHAR(100),
    @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@CategoryName)), '') IS NULL
        THROW 50331, 'The category name is required.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50332, 'You do not have permission to manage categories.', 1;

    IF @CategoryID IS NULL
       AND EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryName = LTRIM(RTRIM(@CategoryName)))
        THROW 50333, 'A category with that name already exists.', 1;

    IF @CategoryID IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM CATEGORIES
           WHERE CategoryName = LTRIM(RTRIM(@CategoryName)) AND CategoryID <> @CategoryID)
        THROW 50333, 'A category with that name already exists.', 1;

    IF @CategoryID IS NULL
    BEGIN
        -- Kani nga branch kay para sa pag-himo ug bag-ong category.
        INSERT INTO CATEGORIES (CategoryName, IsActive)
        VALUES (LTRIM(RTRIM(@CategoryName)), @IsActive);

        INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @ActorUserID, 'CATEGORY_CREATED',
                CONCAT('Category "', LTRIM(RTRIM(@CategoryName)), '" created.'));

        SELECT SCOPE_IDENTITY() AS CategoryID;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM CATEGORIES WHERE CategoryID = @CategoryID)
        THROW 50334, 'The category could not be found.', 1;

    -- Kani nga branch kay para sa rename ug active toggle sa category.
    UPDATE CATEGORIES
    SET CategoryName = LTRIM(RTRIM(@CategoryName)), IsActive = @IsActive
    WHERE CategoryID = @CategoryID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'CATEGORY_UPDATED',
            CONCAT('Category ID ', @CategoryID, ' updated to "',
                   LTRIM(RTRIM(@CategoryName)), '".'));

    SELECT @CategoryID AS CategoryID;
END;
GO

CREATE   PROCEDURE usp_Inventory_UpdateFromDelivery
    @RMID INT,
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (
            SELECT 1 FROM RECEIVING_MEMOS rm WITH (UPDLOCK, HOLDLOCK)
            INNER JOIN DELIVERY_RECEIPTS dr ON dr.DRID = rm.DRID
            WHERE rm.RMID = @RMID AND dr.Status <> 'Rejected'
        )
            THROW 50180, 'The valid receiving memo could not be found.', 1;

        IF EXISTS (SELECT 1 FROM RECEIVING_MEMOS WHERE RMID = @RMID AND InventoryUpdated = 1)
            THROW 50182, 'The inventory has already been updated for this receiving memo.', 1;

        DECLARE @Rows TABLE (ItemID INT PRIMARY KEY, Qty INT);
        INSERT INTO @Rows (ItemID, Qty)
        SELECT ItemID, SUM(QuantityReceived)
        FROM RECEIVING_MEMO_DETAILS
        WHERE RMID = @RMID
        GROUP BY ItemID;

        IF NOT EXISTS (SELECT 1 FROM @Rows)
            THROW 50181, 'The receiving memo has no item details.', 1;

        DECLARE @ItemID INT, @Qty INT, @OldQty INT, @NewQty INT;
        DECLARE item_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT ItemID, Qty FROM @Rows;
        OPEN item_cursor;
        FETCH NEXT FROM item_cursor INTO @ItemID, @Qty;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @OldQty = QuantityOnHand
            FROM INVENTORY WITH (UPDLOCK, HOLDLOCK)
            WHERE ItemID = @ItemID;

            IF @OldQty IS NULL
            BEGIN
                INSERT INTO INVENTORY (ItemID, QuantityOnHand, QuantityReserved)
                VALUES (@ItemID, 0, 0);
                SET @OldQty = 0;
            END;

            SET @NewQty = @OldQty + @Qty;

            UPDATE INVENTORY
            SET QuantityOnHand = @NewQty, LastUpdated = SYSDATETIME()
            WHERE ItemID = @ItemID;

            INSERT INTO INVENTORY_LOGS
                (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
            VALUES
                (@ItemID, @UserID, 'Stock In', @Qty, @OldQty, @NewQty, 'ReceivingMemo', @RMID, 'This stock originated from a receiving memo.');

            FETCH NEXT FROM item_cursor INTO @ItemID, @Qty;
        END;

        CLOSE item_cursor;
        DEALLOCATE item_cursor;

        -- Kani nga bahin mo-reserve sa available stock para sa approved nga requisition details nga naghulat.
        DECLARE @WaitDetailID INT, @WaitItemID INT, @Need INT, @AvailableNow INT, @ReserveNow INT, @CurrentOnHand INT;
        DECLARE wait_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT rd.RequisitionDetailID, rd.ItemID,
                   CASE WHEN rd.QuantityApproved - ISNULL(x.ReservedOrFulfilled, 0) > 0
                        THEN rd.QuantityApproved - ISNULL(x.ReservedOrFulfilled, 0) ELSE 0 END AS NeedQty
            FROM REQUISITION_DETAILS rd
            INNER JOIN REQUISITIONS rq ON rq.RequisitionID = rd.RequisitionID
            OUTER APPLY (
                SELECT SUM(ir.QuantityReserved) AS ReservedOrFulfilled
                FROM INVENTORY_RESERVATIONS ir
                WHERE ir.RequisitionDetailID = rd.RequisitionDetailID
                  AND ir.Status IN ('Active', 'Fulfilled')
            ) x
            WHERE rd.Status IN ('Approved', 'Partially Fulfilled')
              AND rq.Status = 'Approved'
              AND rd.QuantityApproved IS NOT NULL
              AND rd.QuantityApproved > ISNULL(x.ReservedOrFulfilled, 0)
            ORDER BY rq.RequestDate, rd.RequisitionDetailID;

        OPEN wait_cursor;
        FETCH NEXT FROM wait_cursor INTO @WaitDetailID, @WaitItemID, @Need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @AvailableNow = QuantityAvailable, @CurrentOnHand = QuantityOnHand
            FROM INVENTORY WITH (UPDLOCK, HOLDLOCK)
            WHERE ItemID = @WaitItemID;

            IF @AvailableNow IS NOT NULL AND @AvailableNow > 0 AND @Need > 0
            BEGIN
                SET @ReserveNow = CASE WHEN @AvailableNow < @Need THEN @AvailableNow ELSE @Need END;

                UPDATE INVENTORY
                SET QuantityReserved = QuantityReserved + @ReserveNow, LastUpdated = SYSDATETIME()
                WHERE ItemID = @WaitItemID AND QuantityAvailable >= @ReserveNow;

                IF @@ROWCOUNT = 1
                BEGIN
                    INSERT INTO INVENTORY_RESERVATIONS (RequisitionDetailID, QuantityReserved, Status)
                    VALUES (@WaitDetailID, @ReserveNow, 'Active');

                    INSERT INTO INVENTORY_LOGS
                        (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
                    VALUES
                        (@WaitItemID, @UserID, 'Reservation', 0, @CurrentOnHand, @CurrentOnHand,
                         'RequisitionDetail', @WaitDetailID, 'This stock was reserved from a new delivery.');
                END;
            END;

            FETCH NEXT FROM wait_cursor INTO @WaitDetailID, @WaitItemID, @Need;
        END;
        CLOSE wait_cursor;
        DEALLOCATE wait_cursor;

        UPDATE RECEIVING_MEMOS
        SET InventoryUpdated = 1
        WHERE RMID = @RMID AND InventoryUpdated = 0;

        IF @@ROWCOUNT = 0
            THROW 50183, 'The inventory has already been updated for this receiving memo.', 1;

        UPDATE PURCHASE_ORDERS
        SET Status =
            CASE
                WHEN (
                    SELECT ISNULL(SUM(rmd.QuantityReceived), 0)
                    FROM RECEIVING_MEMO_DETAILS rmd
                    INNER JOIN RECEIVING_MEMOS rm ON rm.RMID = rmd.RMID
                    INNER JOIN DELIVERY_RECEIPTS dr ON dr.DRID = rm.DRID
                    WHERE dr.POID = PURCHASE_ORDERS.POID
                ) >= QuantityOrdered THEN 'Delivered'
                ELSE 'Partially Delivered'
            END
        WHERE POID = (
            SELECT dr.POID
            FROM RECEIVING_MEMOS rm
            INNER JOIN DELIVERY_RECEIPTS dr ON dr.DRID = rm.DRID
            WHERE rm.RMID = @RMID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'wait_cursor') >= 0 CLOSE wait_cursor;
        IF CURSOR_STATUS('local', 'wait_cursor') >= -1 DEALLOCATE wait_cursor;
        IF CURSOR_STATUS('local', 'item_cursor') >= 0 CLOSE item_cursor;
        IF CURSOR_STATUS('local', 'item_cursor') >= -1 DEALLOCATE item_cursor;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE usp_Inventory_UpdateItem
    @ActorUserID INT,
    @ItemID INT,
    @ItemCode VARCHAR(30),
    @ItemName NVARCHAR(200),
    @CategoryID INT,
    @UnitOfMeasure NVARCHAR(40),
    @ReorderPoint INT,
    @UnitPrice DECIMAL(18,2),
    @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ItemCode)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@ItemName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@UnitOfMeasure)), '') IS NULL
        THROW 50307, 'Item code, name, and unit of measure are required.', 1;

    IF @ReorderPoint < 0 OR @UnitPrice < 0
        THROW 50308, 'Reorder point and unit price cannot be negative.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM USERS u
        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
          AND p.PermissionCode = N'inventory.update'
    )
        THROW 50309, 'You do not have permission to update inventory items.', 1;

    IF NOT EXISTS (SELECT 1 FROM ITEMS WHERE ItemID = @ItemID)
        THROW 50310, 'The item could not be found.', 1;

    -- Kani nga check kay para masiguro nga gikan sa master list ang UoM.
    IF NOT EXISTS (
        SELECT 1 FROM UNIT_OF_MEASURES
        WHERE UomName = @UnitOfMeasure COLLATE DATABASE_DEFAULT AND IsActive = 1
    )
        THROW 50370, 'The unit of measure must be selected from the unit of measures list.', 1;

    IF EXISTS (SELECT 1 FROM ITEMS WHERE ItemCode = @ItemCode AND ItemID <> @ItemID)
        THROW 50311, 'The item code is already used by another item.', 1;

    UPDATE ITEMS
    SET ItemCode = @ItemCode, ItemName = @ItemName, CategoryID = @CategoryID,
        UnitOfMeasure = @UnitOfMeasure, ReorderPoint = @ReorderPoint,
        UnitPrice = @UnitPrice, IsActive = @IsActive
    WHERE ItemID = @ItemID;

    INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
    VALUES (@ActorUserID, @ActorUserID, 'INVENTORY_ITEM_UPDATED',
            CONCAT('Item ', @ItemCode, ' details updated.'));
END;
GO

/* Kani nga procedure para ma-record ang failed login attempt.
   Kung moabot og 5 ang failed attempts, 15 minutos nga lockout. */
CREATE   PROCEDURE dbo.usp_Login_Failed
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

/* ============================================================
   A. LOGIN UG SESSION
   ============================================================ */

/* Kani nga procedure para makuha ang account details sa login.
   Apil na ang RoleName para kabalo ang app asa siya mo-redirect. */
CREATE   PROCEDURE dbo.usp_Login_GetUser
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

/* Kani nga procedure para ma-reset ang failed attempts kung
   sakto ang password, ug ma-log ang LastLogin. */
CREATE   PROCEDURE dbo.usp_Login_Succeeded
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

CREATE   PROCEDURE usp_Notification_Create
    @RecipientUserID INT,
    @NotificationType VARCHAR(50),
    @Title NVARCHAR(150),
    @Message NVARCHAR(1000),
    @RelatedEntityType VARCHAR(50) = NULL,
    @RelatedEntityID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @RecipientUserID AND IsActive = 1)
        THROW 50300, 'The recipient does not exist or is inactive.', 1;
    IF NULLIF(LTRIM(RTRIM(@NotificationType)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@Title)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@Message)), '') IS NULL
        THROW 50301, 'The notification details must be complete.', 1;

    INSERT INTO NOTIFICATIONS
        (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID)
    VALUES
        (@RecipientUserID, @NotificationType, @Title, @Message, @RelatedEntityType, @RelatedEntityID);

    SELECT CONVERT(BIGINT, SCOPE_IDENTITY()) AS NotificationID;
END;
GO

-- Kani nga procedure para markahan nga nabasa na ang notification sa tag-iya niini.
CREATE   PROCEDURE usp_Notification_MarkRead
    @NotificationID BIGINT,
    @UserID INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE NOTIFICATIONS
    SET IsRead = 1, ReadAt = COALESCE(ReadAt, SYSDATETIME())
    WHERE NotificationID = @NotificationID
      AND RecipientUserID = @UserID
      AND IsRead = 0;
    SELECT @@ROWCOUNT AS RowsUpdated;
END;
GO

/* ================================================================
   V005 - NOTIFICATIONS MODULE
   ----------------------------------------------------------------
   Kani nga migration kay para sa Notifications page:
     1. usp_Notifications_GetByUser - mga notification sa current
        user (unread una, dayon pinakabag-o).
     2. usp_Notifications_MarkRead - mark read usa o tanan.
   Ang mga notifications kay gihimo na sa issuance/receiving engine
   (STOCK_ALLOCATED, LOW_STOCK, STOCK_SHORTAGE) per Figure 8 -
   diri lang sila gikonsulta ug gi-mark read. Idempotent kini.
   ================================================================ */

/* ----------------------------------------------------------------
   1. GET BY USER - top 50 nga notification sa user, unread una.
   ---------------------------------------------------------------- */
CREATE   PROCEDURE usp_Notifications_GetByUser
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga check kay para sa valid nga active user ra.
    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ActorUserID AND IsActive = 1)
        THROW 50350, 'Your account is inactive or was not found.', 1;

    SELECT TOP (50) n.NotificationID, n.NotificationType, n.Title, n.Message,
           n.RelatedEntityType, n.RelatedEntityID, n.IsRead, n.CreatedAt
    FROM NOTIFICATIONS n
    WHERE n.RecipientUserID = @ActorUserID
    ORDER BY n.IsRead ASC, n.CreatedAt DESC;
END;
GO

/* ----------------------------------------------------------------
   2. MARK READ - usa ka notification (kung naay ID) o tanan
      unread. Ang RecipientUserID filter kay para dili ma-mark
      read sa laing user ang notification nga dili iya.
   ---------------------------------------------------------------- */
CREATE   PROCEDURE usp_Notifications_MarkRead
    @ActorUserID INT,
    @NotificationID BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ActorUserID AND IsActive = 1)
        THROW 50351, 'Your account is inactive or was not found.', 1;

    IF @NotificationID IS NOT NULL
    BEGIN
        UPDATE NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationID = @NotificationID AND RecipientUserID = @ActorUserID AND IsRead = 0;
    END
    ELSE
    BEGIN
        UPDATE NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE RecipientUserID = @ActorUserID AND IsRead = 0;
    END;
END;
GO

-- Kani nga procedure nagkuha sa tanang permission definitions.
CREATE   PROCEDURE usp_Permissions_GetAll
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

/* ============================================================
   2. PURCHASING PO APPROVAL (NO DUPLICATE PO_APPROVED) &
      TRIGGER AUTO-MARK ON DISPATCH/COMPLETION
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_ApprovePO
    @POID INT,
    @ApproverUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.approve'
        )
            THROW 50320, 'Approval permission is required to approve a purchase order.', 1;

        DECLARE @Amount DECIMAL(12,2), @BudgetYear INT, @Status VARCHAR(30), @BudgetAmount DECIMAL(14,2), @Committed DECIMAL(14,2);
        SELECT @Amount = TotalAmount, @BudgetYear = YEAR(DateIssued), @Status = Status
        FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE POID = @POID;

        IF @Amount IS NULL
            THROW 50321, 'The purchase order could not be found.', 1;
        IF @Status <> 'Pending Approval'
            THROW 50322, 'The purchase order (PO) must be in Pending Approval status.', 1;

        DECLARE @POCreatorUserID INT = COALESCE(
            (
                SELECT TOP (1) ds.SignerUserID
                FROM dbo.DOCUMENT_SIGNATURES ds
                WHERE ds.DocumentType = 'PURCHASE_ORDER'
                  AND ds.DocumentID = @POID
                  AND ds.Stage = 'Requested'
                  AND ds.IsActive = 1
                ORDER BY ds.SignatureID DESC
            ),
            (
                SELECT pr.CreatedByUserID
                FROM dbo.PURCHASE_ORDERS po
                INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
                WHERE po.POID = @POID
            )
        );

        IF @POCreatorUserID = @ApproverUserID
            THROW 50326, 'You cannot approve your own purchase order. Another authorized approver must review it.', 1;

        SELECT @BudgetAmount = BudgetAmount
        FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
        WHERE BudgetYear = @BudgetYear AND IsActive = 1;

        IF @BudgetAmount IS NULL
            THROW 50323, 'The approved budget for this year has not been configured yet.', 1;

        SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
        FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered');

        IF @Committed + @Amount > @BudgetAmount
            THROW 50324, 'The purchase order exceeds the remaining annual budget.', 1;

        UPDATE dbo.PURCHASE_ORDERS
        SET Status = 'Approved', ApprovedByUserID = @ApproverUserID
        WHERE POID = @POID AND Status = 'Pending Approval';

        IF @@ROWCOUNT <> 1
            THROW 50325, 'The purchase order could not be updated.', 1;

        UPDATE dbo.PURCHASE_REQUESTS
        SET Status = 'Approved'
        WHERE PRID IN (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID)
           OR PRID = (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID);

        /* PO_APPROVED and PO_PENDING_APPROVAL read-state are handled cleanly
           by dbo.trg_Purchasing_PONotifications (single source of truth). */

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/*
   5. BUSINESS ACTION WRAPPERS
 */

/* PO approval + signature. Ang existing usp_Purchasing_ApprovePO
   ang naghimo sa budget/status checks, so usa ra ang engine. */
CREATE   PROCEDURE dbo.usp_Purchasing_ApprovePOWithSignature
    @POID INT,
    @ApproverUserID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before approving the purchase order.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50730,
            'A signature is required to approve a purchase order.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Purchasing_ApprovePO
            @POID = @POID,
            @ApproverUserID = @ApproverUserID;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ApproverUserID,
            @DocumentType = 'PURCHASE_ORDER',
            @DocumentID = @POID,
            @Stage = 'Approved',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ApproverUserID,
            @ApproverUserID,
            'PURCHASING_ACTION',
            CONCAT('ApprovePO; PO=', @POID, '; PO approved with digital signature.')
        );

        COMMIT TRANSACTION;

        SELECT @POID AS ID, N'PO approved.' AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   8. EMAIL LOGGING & RUNTIME CONFIG â€” PERMISSION-BASED GATES
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_BeginEmailLog
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
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN (N'purchasing.manage', N'requisitions.approve')
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

/* ============================================================
   3. COMPLETE EMAIL LOG (Sent / Failed + auto-dispatch PO)
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_CompleteEmailLog
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

-- Kani nga procedure para makahimo og PO gikan sa usa o daghang PR nga parehas og item ug supplier.
CREATE   PROCEDURE usp_Purchasing_CreatePO
    @PRIDs NVARCHAR(MAX),
    @CreatedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Selected TABLE (PRID INT PRIMARY KEY, RepFID INT, ItemID INT, Qty INT, SupplierID INT, UnitPrice DECIMAL(10,2));
    INSERT INTO @Selected (PRID, RepFID, ItemID, Qty, SupplierID, UnitPrice)
    SELECT pr.PRID, rr.RepFID, rr.ItemID, rr.QuantityNeeded, q.SupplierID, q.QuotedPrice
    FROM STRING_SPLIT(@PRIDs, ',') ss
    INNER JOIN PURCHASE_REQUESTS pr ON pr.PRID = TRY_CONVERT(INT, LTRIM(RTRIM(ss.value)))
    INNER JOIN REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
    INNER JOIN SUPPLIER_QUOTATIONS q ON q.PRID = pr.PRID AND q.IsRecommended = 1
    WHERE pr.Status IN ('Open', 'Approved')
      AND rr.Status = 'Processed';

    IF NOT EXISTS (SELECT 1 FROM @Selected)
        THROW 50150, 'There are no valid purchase requests with recommended quotations.', 1;

    IF (SELECT COUNT(DISTINCT ItemID) FROM @Selected) > 1
        THROW 50151, 'Only items of the same type can be consolidated into a single purchase order (PO).', 1;

    IF (SELECT COUNT(*) FROM @Selected) <> (SELECT COUNT(DISTINCT TRY_CONVERT(INT, LTRIM(RTRIM(value)))) FROM STRING_SPLIT(@PRIDs, ','))
        THROW 50152, 'There are invalid purchase requests (PRs) with no quotations or that are not open.', 1;

    IF (SELECT COUNT(DISTINCT SupplierID) FROM @Selected) <> 1
        THROW 50153, 'Only purchase requests with the same recommended supplier can be included in a single purchase order (PO).', 1;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @CreatedByUserID AND IsActive = 1)
        THROW 50154, 'The user does not exist or is inactive.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @SupplierID INT, @Qty INT, @UnitPrice DECIMAL(10,2), @Total DECIMAL(12,2), @PRID INT, @POID INT;
        SELECT @SupplierID = MIN(SupplierID), @Qty = SUM(Qty), @UnitPrice = MIN(UnitPrice) FROM @Selected;

        IF EXISTS (SELECT 1 FROM @Selected WHERE UnitPrice <> @UnitPrice)
            THROW 50155, 'The quotations must have the same unit price to be consolidated.', 1;

        SET @Total = CONVERT(DECIMAL(12,2), @Qty * @UnitPrice);

        INSERT INTO PURCHASE_ORDERS (PRID, SupplierID, QuantityOrdered, UnitPrice, TotalAmount, Status)
        SELECT MIN(PRID), @SupplierID, @Qty, @UnitPrice, @Total, 'Pending Approval'
        FROM @Selected;

        SET @POID = SCOPE_IDENTITY();

        INSERT INTO PO_PR_Mapping (POID, PRID)
        SELECT @POID, PRID FROM @Selected;

        UPDATE PURCHASE_REQUESTS SET Status = 'Processed'
        WHERE PRID IN (SELECT PRID FROM @Selected);

        COMMIT TRANSACTION;
        SELECT @POID AS POID, @Total AS TotalAmount;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Kani nga procedure para himuon nga purchase request ang active replenishment request.
CREATE   PROCEDURE usp_Purchasing_CreatePR
    @RepFID INT,
    @CreatedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (
            SELECT 1 FROM REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID AND Status = 'Pending'
        )
            THROW 50130, 'The pending replenishment request could not be found.', 1;

        IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @CreatedByUserID AND IsActive = 1)
            THROW 50131, 'The user does not exist or is inactive.', 1;

        IF EXISTS (SELECT 1 FROM PURCHASE_REQUESTS WHERE RepFID = @RepFID)
            THROW 50132, 'A purchase request already exists for this replenishment request.', 1;

        INSERT INTO PURCHASE_REQUESTS (RepFID, CreatedByUserID, Status)
        VALUES (@RepFID, @CreatedByUserID, 'Open');

        DECLARE @PRID INT = SCOPE_IDENTITY();

        UPDATE REPLENISHMENT_REQUESTS SET Status = 'Processed' WHERE RepFID = @RepFID;

        COMMIT TRANSACTION;
        SELECT @PRID AS PRID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE dbo.usp_Purchasing_GetCheckedDRQueue
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
          AND p.PermissionCode IN ('receiving.view', 'receiving.manage')
    )
        THROW 50530, 'Receiving permission is required.', 1;

    SELECT
        dr.DRID,
        dr.POID,
        tr.SupplierDRNumber,
        pr.RepFID,
        dd.ItemID,
        i.ItemCode,
        i.ItemName,
        dd.QuantityAccepted,
        dr.DeliveryDate,
        dr.Notes
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
    INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
    INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
    INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
    -- Kani nga join kay para ang RepF nga na-receive na (Processed/
    -- Cancelled) dili na mo-gawas ang DR niini.
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID AND rr.Status = 'Pending'
    INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
    WHERE dd.QuantityAccepted > 0
      AND dr.Status <> 'Rejected'
      AND po.Status IN ('Sent to Supplier', 'Partially Delivered')
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.RECEIVING_MEMOS rm
          WHERE rm.DRID = dr.DRID
      )
    ORDER BY dr.DeliveryDate, dr.DRID;
END;
GO

/* ============================================================
   1. PURCHASE ORDER PRINT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_GetPurchaseOrderPrint
    @ActorUserID INT,
    @POID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('purchasing.view', 'purchasing.manage')
    )
        THROW 50601,
            'You do not have permission to print purchase orders.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.PURCHASE_ORDERS
        WHERE POID = @POID
    )
        RETURN;

    SELECT
        po.POID,
        po.PRID,
        po.Status,
        po.DateIssued,
        po.QuantityOrdered,
        po.UnitPrice,
        po.TotalAmount,
        t.ExpectedDate,
        t.DispatchedAt,
        t.DecisionReason,
        s.SupplierCode,
        s.SupplierName,
        LTRIM(RTRIM(CONCAT(
            s.ContactPersonFirstName,
            ' ',
            ISNULL(s.ContactPersonMiddleName + ' ', ''),
            s.ContactPersonLastName
        ))) AS SupplierContact,
        s.Phone AS SupplierPhone,
        s.Email AS SupplierEmail,
        s.Address AS SupplierAddress,
        rr.RepFID,
        rr.OriginRequisitionID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        cat.CategoryName,
        LTRIM(RTRIM(CONCAT(
            approver.FirstName, ' ', approver.LastName
        ))) AS ApprovedByName,
        LTRIM(RTRIM(CONCAT(
            creator.FirstName, ' ', creator.LastName
        ))) AS RequestedByName,
        ISNULL(a.AcceptedQuantity, 0) AS AcceptedQuantity,
        po.QuantityOrdered - ISNULL(a.AcceptedQuantity, 0)
            AS OutstandingQuantity,
        ISNULL(m.StockedQuantity, 0) AS StockedQuantity,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline
    FROM dbo.PURCHASE_ORDERS po
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = po.PRID
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = po.SupplierID
    LEFT JOIN dbo.CATEGORIES cat
        ON cat.CategoryID = i.CategoryID
    LEFT JOIN dbo.USERS approver
        ON approver.UserID = po.ApprovedByUserID
    LEFT JOIN dbo.USERS creator
        ON creator.UserID = pr.CreatedByUserID
    LEFT JOIN dbo.PURCHASING_PO_TRACKING t
        ON t.POID = po.POID
    OUTER APPLY
    (
        SELECT SUM(drd.QuantityAccepted) AS AcceptedQuantity
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd
            ON drd.DRID = dr.DRID
        WHERE dr.POID = po.POID
    ) a
    OUTER APPLY
    (
        SELECT SUM(rmd.QuantityReceived) AS StockedQuantity
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.RECEIVING_MEMOS rm
            ON rm.DRID = dr.DRID
        INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd
            ON rmd.RMID = rm.RMID
        WHERE dr.POID = po.POID
          AND rm.InventoryUpdated = 1
    ) m
    WHERE po.POID = @POID;
END;
GO

/* ============================================================
   5. RETURN SLIP (REJECTED SUPPLIER DELIVERY)
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_GetReturnSlip
    @ActorUserID INT,
    @DRID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('purchasing.view', 'purchasing.manage')
    )
        THROW 50605,
            'You do not have permission to print return slips.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERY_RECEIPTS
        WHERE DRID = @DRID
    )
        RETURN;

    /* Result set 1: return slip header. */
    SELECT
        dr.DRID,
        dr.POID,
        tr.SupplierDRNumber,
        dr.DeliveryDate,
        dr.Status,
        dr.Notes,
        s.SupplierCode,
        s.SupplierName,
        LTRIM(RTRIM(CONCAT(
            s.ContactPersonFirstName,
            ' ',
            ISNULL(s.ContactPersonMiddleName + ' ', ''),
            s.ContactPersonLastName
        ))) AS SupplierContact,
        s.Phone AS SupplierPhone,
        s.Email AS SupplierEmail,
        s.Address AS SupplierAddress,
        po.Status AS POStatus,
        po.QuantityOrdered,
        po.UnitPrice,
        po.TotalAmount,
        rr.RepFID,
        rr.OriginRequisitionID,
        LTRIM(RTRIM(CONCAT(
            recordedBy.FirstName, ' ', recordedBy.LastName
        ))) AS RecordedByName,
        tr.ReplacementRequestedAt,
        po.QuantityOrdered - ISNULL(a.AcceptedQuantity, 0)
            AS OutstandingQuantity,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.POID = dr.POID
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = po.PRID
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = po.SupplierID
    LEFT JOIN dbo.PURCHASING_DR_TRACKING tr
        ON tr.DRID = dr.DRID
    LEFT JOIN dbo.USERS recordedBy
        ON recordedBy.UserID = tr.RecordedByUserID
    OUTER APPLY
    (
        SELECT SUM(drd.QuantityAccepted) AS AcceptedQuantity
        FROM dbo.DELIVERY_RECEIPTS dr2
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd
            ON drd.DRID = dr2.DRID
        WHERE dr2.POID = po.POID
    ) a
    WHERE dr.DRID = @DRID;

    /* Result set 2: delivered/accepted/rejected line items. */
    SELECT
        dd.DRDetailID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        dd.QuantityDelivered,
        dd.QuantityAccepted,
        dd.QuantityRejected,
        dd.Remarks
    FROM dbo.DELIVERY_RECEIPT_DETAILS dd
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = dd.ItemID
    WHERE dd.DRID = @DRID
    ORDER BY dd.DRDetailID;
END;
GO

/* ============================================================
   3. RECEIVE CHECKED DR -> NOTIFY PURCHASING THAT PO STOCKED IN
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_ReceiveCheckedDR
    @ActorUserID INT,
    @DRID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN (N'receiving.manage', N'purchasing.manage')
    )
        THROW 50530, 'Receiving or Purchasing management permission is required.', 1;

    DECLARE
        @LockResult INT,
        @POID INT,
        @RepFID INT,
        @ItemID INT,
        @Accepted INT,
        @Baseline INT,
        @ActualReceived INT,
        @PriorApplied INT,
        @RMID INT,
        @ReceivedForPO INT,
        @Ordered INT,
        @Remarks NVARCHAR(1000);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50502, 'Purchasing is busy. Please try again.', 1;

        SELECT
            @POID = dr.POID,
            @RepFID = pr.RepFID,
            @ItemID = dd.ItemID,
            @Accepted = dd.QuantityAccepted,
            @Baseline = pt.ReceivedBeforeOrder,
            @Ordered = po.QuantityOrdered
        FROM dbo.DELIVERY_RECEIPTS dr WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.PURCHASING_DR_TRACKING dt ON dt.DRID = dr.DRID
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.PURCHASING_PO_TRACKING pt ON pt.POID = po.POID
        WHERE dr.DRID = @DRID
          AND dr.Status <> 'Rejected'
          AND po.Status IN ('Sent to Supplier', 'Partially Delivered');

        IF @Accepted IS NULL OR @Accepted <= 0
            THROW 50531, 'No eligible accepted quantity exists for this checked DR.', 1;

        IF
        (
            SELECT COUNT(*) FROM dbo.DELIVERY_RECEIPT_DETAILS
            WHERE DRID = @DRID
        ) <> 1
            THROW 50531, 'This receiving bridge supports one PO item per DR.', 1;

        IF EXISTS
        (
            SELECT 1 FROM dbo.RECEIVING_MEMOS
            WHERE DRID = @DRID
        )
            THROW 50532, 'This DR already has a Receiving Memo.', 1;

        SELECT @ActualReceived = QuantityReceived
        FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
        WHERE RepFID = @RepFID;

        SELECT @PriorApplied = ISNULL(SUM(rmd.QuantityReceived), 0)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
        INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
        WHERE dr.POID = @POID
          AND rm.InventoryUpdated = 1;

        IF @ActualReceived IS NULL
           OR @ActualReceived <> @Baseline + @PriorApplied
            THROW 50533, 'This replenishment has receipts outside the checked-DR workflow. Reconcile them before receiving this DR.', 1;

        IF @PriorApplied + @Accepted > @Ordered
            THROW 50534, 'Receiving would exceed the PO quantity.', 1;

        SET @Remarks = CONCAT(
            'Accepted supplier delivery: PO #', @POID,
            ', DR #', @DRID, '.'
        );

        INSERT INTO dbo.RECEIVING_MEMOS
            (DRID, ReceivedByUserID, Remarks, InventoryUpdated)
        VALUES
            (@DRID, @ActorUserID, @Remarks, 0);

        SET @RMID = SCOPE_IDENTITY();

        INSERT INTO dbo.RECEIVING_MEMO_DETAILS
            (RMID, ItemID, QuantityReceived)
        VALUES
            (@RMID, @ItemID, @Accepted);

        EXEC dbo.usp_Inventory_ReceiveStock
            @ActorUserID = @ActorUserID,
            @ItemID = @ItemID,
            @QuantityReceived = @Accepted,
            @RepFID = @RepFID,
            @Remarks = @Remarks;

        UPDATE dbo.RECEIVING_MEMOS
        SET InventoryUpdated = 1
        WHERE RMID = @RMID;

        SET @ReceivedForPO = @PriorApplied + @Accepted;

        UPDATE dbo.PURCHASE_ORDERS
        SET Status = CASE
            WHEN @ReceivedForPO >= QuantityOrdered THEN 'Delivered'
            ELSE 'Partially Delivered'
        END
        WHERE POID = @POID;

        IF @ReceivedForPO >= @Ordered
        BEGIN
            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Closed'
            WHERE PRID =
                (SELECT PRID FROM dbo.PURCHASE_ORDERS WHERE POID = @POID);
        END;

        UPDATE dbo.NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationType = 'PURCHASE_DELIVERY'
          AND RelatedEntityType = 'DELIVERY_RECEIPT'
          AND RelatedEntityID = @DRID
          AND IsRead = 0;

        /* Notify Purchasing that checked supplier stock has been received into inventory */
        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID,
            IsRead,
            CreatedAt
        )
        SELECT DISTINCT
            u.UserID,
            'PO_RECEIVED',
            'Supplier delivery stocked into inventory',
            CONCAT(
                'PO #', @POID,
                ' (DR #', @DRID, ', ', @Accepted, ' unit(s)) has been received via RM #', @RMID, '.'),
            'PURCHASE_ORDER',
            @POID,
            0,
            SYSDATETIME()
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND p.PermissionCode = N'purchasing.manage';

        INSERT INTO dbo.USER_AUDIT_LOGS
            (ActorUserID, TargetUserID, ActionType, Description)
        VALUES
            (@ActorUserID, @ActorUserID, 'PURCHASE_DR_RECEIVED',
             CONCAT('DR #', @DRID, ' received through RM #', @RMID,
                    '. Quantity: ', @Accepted, '.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   1. RECONCILE CANCELLED REQUISITION DEMAND
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_ReconcileCancelledDemand
    @RequisitionID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Cancelled'
    )
        RETURN;

    DECLARE
        @RepFID INT,
        @ItemID INT,
        @Available INT,
        @Reorder INT,
        @Unallocated INT,
        @OtherIncoming INT,
        @Needed INT,
        @NextOrigin INT;

    DECLARE candidates CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            rr.RepFID,
            rr.ItemID
        FROM dbo.REPLENISHMENT_REQUESTS rr WITH (UPDLOCK, HOLDLOCK)
        WHERE rr.OriginRequisitionID = @RequisitionID
          AND rr.Status = 'Pending'
          AND rr.QuantityReceived = 0
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PURCHASE_REQUESTS pr
              WHERE pr.RepFID = rr.RepFID
          )
        ORDER BY rr.RepFID;

    OPEN candidates;

    FETCH NEXT FROM candidates
    INTO @RepFID, @ItemID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @Available = NULL,
            @Reorder = NULL,
            @NextOrigin = NULL;

        SELECT
            @Available =
                CASE
                    WHEN inv.QuantityOnHand > inv.QuantityReserved
                        THEN inv.QuantityOnHand - inv.QuantityReserved
                    ELSE 0
                END,
            @Reorder = i.ReorderPoint
        FROM dbo.INVENTORY inv WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.ITEMS i
            ON i.ItemID = inv.ItemID
        WHERE inv.ItemID = @ItemID;

        IF @Available IS NULL
            THROW 50631,
                'Cannot reconcile cancelled demand: the item stock record is missing.',
                1;

        SELECT
            @Unallocated = ISNULL
            (
                SUM
                (
                    CASE
                        WHEN ISNULL(rd.QuantityApproved, rd.QuantityRequested)
                             > ISNULL(res.Qty, 0)
                        THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested)
                             - ISNULL(res.Qty, 0)
                        ELSE 0
                    END
                ),
                0
            )
        FROM dbo.REQUISITION_DETAILS rd
        INNER JOIN dbo.REQUISITIONS rq
            ON rq.RequisitionID = rd.RequisitionID
        OUTER APPLY
        (
            SELECT SUM(ir.QuantityReserved) AS Qty
            FROM dbo.INVENTORY_RESERVATIONS ir
            WHERE ir.RequisitionDetailID = rd.RequisitionDetailID
              AND ir.Status = 'Active'
        ) res
        WHERE rd.ItemID = @ItemID
          AND rq.Status = 'Approved'
          AND rd.Status IN ('Pending', 'Partially Fulfilled');

        SELECT
            @OtherIncoming = ISNULL
            (
                SUM(rr.QuantityNeeded - rr.QuantityReceived),
                0
            )
        FROM dbo.REPLENISHMENT_REQUESTS rr
        WHERE rr.ItemID = @ItemID
          AND rr.Status = 'Pending'
          AND rr.RepFID <> @RepFID
          AND rr.QuantityNeeded > rr.QuantityReceived
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.REQUISITIONS rq
              WHERE rq.RequisitionID = rr.OriginRequisitionID
                AND rq.Status = 'Cancelled'
          );

        /*
            Preserve independently valid demand.

            A cancelled requisition does not necessarily mean that
            the item no longer needs replenishment.
        */
        SET @Needed =
            CASE
                WHEN @Unallocated > ISNULL(@Reorder, 0)
                    THEN @Unallocated
                ELSE ISNULL(@Reorder, 0)
            END
            - @Available
            - @OtherIncoming;

        IF @Needed > 0
        BEGIN
            SELECT TOP (1)
                @NextOrigin = rd.RequisitionID
            FROM dbo.REQUISITION_DETAILS rd
            INNER JOIN dbo.REQUISITIONS rq
                ON rq.RequisitionID = rd.RequisitionID
            WHERE rd.ItemID = @ItemID
              AND rq.Status = 'Approved'
              AND rd.Status IN ('Pending', 'Partially Fulfilled')
            ORDER BY
                rq.RequestDate,
                rd.RequisitionDetailID;

            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET
                QuantityNeeded = @Needed,
                OriginRequisitionID = @NextOrigin
            WHERE RepFID = @RepFID;
        END
        ELSE
        BEGIN
            UPDATE dbo.REPLENISHMENT_REQUESTS
            SET Status = 'Cancelled'
            WHERE RepFID = @RepFID;
        END;

        UPDATE dbo.NOTIFICATIONS
        SET
            IsRead = 1,
            ReadAt = SYSDATETIME()
        WHERE RelatedEntityType = 'REPLENISHMENT_REQUEST'
          AND RelatedEntityID = @RepFID
          AND NotificationType = 'STOCK_SHORTAGE'
          AND IsRead = 0;

        FETCH NEXT FROM candidates
        INTO @RepFID, @ItemID;
    END;

    CLOSE candidates;
    DEALLOCATE candidates;
END;
GO

-- Kani nga procedure para mag-save o mo-update sa supplier quotation ug recommendation.
CREATE   PROCEDURE usp_Purchasing_SaveQuotation
    @PRID INT,
    @SupplierID INT,
    @QuotedPrice DECIMAL(10,2),
    @IsRecommended BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @QuotedPrice < 0
        THROW 50140, 'The quotation price cannot be negative.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM PURCHASE_REQUESTS WHERE PRID = @PRID AND Status IN ('Open', 'Pending Approval'))
            THROW 50141, 'The purchase request is not open for quotations.', 1;

        IF NOT EXISTS (SELECT 1 FROM SUPPLIERS WHERE SupplierID = @SupplierID AND IsActive = 1)
            THROW 50142, 'The active supplier could not be found.', 1;

        IF @IsRecommended = 1
            UPDATE SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID AND IsRecommended = 1 AND SupplierID <> @SupplierID;

        IF EXISTS (SELECT 1 FROM SUPPLIER_QUOTATIONS WHERE PRID = @PRID AND SupplierID = @SupplierID)
            UPDATE SUPPLIER_QUOTATIONS
            SET QuotedPrice = @QuotedPrice, IsRecommended = @IsRecommended, DateQuoted = SYSDATETIME()
            WHERE PRID = @PRID AND SupplierID = @SupplierID;
        ELSE
            INSERT INTO SUPPLIER_QUOTATIONS (PRID, SupplierID, QuotedPrice, IsRecommended)
            VALUES (@PRID, @SupplierID, @QuotedPrice, @IsRecommended);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   5. PURCHASING BUDGET, PO APPROVAL & SELF-APPROVAL GUARDS
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Purchasing_SetBudget
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
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50311, 'Settings management permission is required to configure the purchasing budget.', 1;

    IF EXISTS (
        SELECT 1 FROM dbo.PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    ) AND @BudgetAmount < (
        SELECT ISNULL(SUM(TotalAmount), 0) FROM dbo.PURCHASE_ORDERS
        WHERE YEAR(DateIssued) = @BudgetYear
          AND Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
    )
        THROW 50312, 'The budget cannot be set below the total committed purchase orders.', 1;

    MERGE dbo.PURCHASE_BUDGETS AS target
    USING (SELECT @BudgetYear AS BudgetYear) AS source
       ON target.BudgetYear = source.BudgetYear
    WHEN MATCHED THEN UPDATE SET BudgetAmount = @BudgetAmount, IsActive = 1, UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT (BudgetYear, BudgetAmount, IsActive, CreatedByUserID)
         VALUES (@BudgetYear, @BudgetAmount, 1, @ActorUserID);
END;
GO

CREATE   PROCEDURE dbo.usp_PurchasingWorkspace_Action
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@Payload) <> 1
        THROW 50500, 'Invalid purchasing request.', 1;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;
    DECLARE @Admin BIT = 0;

    SELECT
        @Manage = MAX(CASE WHEN p.PermissionCode = N'purchasing.manage' THEN 1 ELSE 0 END),
        @Approve = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END),
        @Admin = MAX(CASE WHEN p.PermissionCode = N'settings.manage' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SET @Manage = ISNULL(@Manage, 0);
    SET @Approve = ISNULL(@Approve, 0);
    SET @Admin = ISNULL(@Admin, 0);

    IF @Action IN ('ApprovePO', 'RejectPO')
    BEGIN
        IF @Approve = 0
            THROW 50501,
                'Approval permission is required to decide a PO.',
                1;
    END
    ELSE IF @Action = 'SetBudget'
    BEGIN
        IF @Admin = 0
            THROW 50501,
                'Settings management permission is required to configure the budget.',
                1;
    END
    ELSE IF @Manage = 0
        THROW 50501,
            'Purchasing management permission is required.',
            1;

    DECLARE
        @PRID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID')),
        @RepFID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.repFID')),
        @POID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.poID')),
        @SupplierID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.supplierID')),
        @FollowupID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.followupID')),
        @DRID INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.drID')),
        @Year INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.year')),
        @ExpectedDate DATE =
            TRY_CONVERT(DATE, JSON_VALUE(@Payload, '$.expectedDate')),
        @PriceRaw DECIMAL(20,6) =
            TRY_CONVERT(DECIMAL(20,6), JSON_VALUE(@Payload, '$.price')),
        @AmountRaw DECIMAL(20,6) =
            TRY_CONVERT(DECIMAL(20,6), JSON_VALUE(@Payload, '$.amount')),
        @Delivered INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.delivered')),
        @Accepted INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.accepted')),
        @Rejected INT =
            TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.rejected'));

    DECLARE @NotesInput NVARCHAR(4000) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@Payload, '$.notes'))), '');

    DECLARE @DRInput NVARCHAR(4000) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@Payload, '$.drNumber'))), '');

    IF LEN(@NotesInput) > 1000
        THROW 50500,
            'Notes must be 1000 characters or fewer.',
            1;

    IF LEN(@DRInput) > 100
        THROW 50500,
            'The supplier DR number must be 100 characters or fewer.',
            1;

    DECLARE @Notes NVARCHAR(1000) = @NotesInput;
    DECLARE @DRNumber NVARCHAR(100) = @DRInput;

    DECLARE
        @ResultID INT,
        @Message NVARCHAR(300) = N'Purchasing action completed.',
        @LockResult INT,
        @Status VARCHAR(30),
        @ItemID INT,
        @Needed INT,
        @Received INT,
        @Remaining INT,
        @Outstanding INT,
        @QuotationID INT,
        @WinnerID INT,
        @Price DECIMAL(10,2),
        @Total DECIMAL(12,2),
        @Budget DECIMAL(14,2),
        @Committed DECIMAL(14,2);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50502,
                'Purchasing is busy. Please try again.',
                1;

        DECLARE @DemandRepFID INT = @RepFID;

        IF @Action IN
        (
            'SaveQuotation',
            'Recommend',
            'CreatePO',
            'RevisePR'
        )
        BEGIN
            SELECT @DemandRepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS
            WHERE PRID = @PRID;
        END;

        IF @Action IN
        (
            'CreatePR',
            'SaveQuotation',
            'Recommend',
            'CreatePO',
            'RevisePR'
        )
        AND EXISTS
        (
            SELECT 1
            FROM dbo.REPLENISHMENT_REQUESTS rr
            INNER JOIN dbo.REQUISITIONS rq
                ON rq.RequisitionID = rr.OriginRequisitionID
            WHERE rr.RepFID = @DemandRepFID
              AND rq.Status = 'Cancelled'
        )
            THROW 50630,
                'The originating requisition was cancelled. Refresh Purchasing before continuing.',
                1;

        /* CREATE PR */

        IF @Action = 'CreatePR'
        BEGIN
            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            IF @Status IS NULL
               OR @Status <> 'Pending'
               OR @Needed <= @Received
                THROW 50503,
                    'Select a pending replenishment with an outstanding quantity.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS
                WHERE RepFID = @RepFID
            )
                THROW 50504,
                    'This replenishment already has a Purchase Request.',
                    1;

            INSERT INTO dbo.PURCHASE_REQUESTS
            (
                RepFID,
                CreatedByUserID,
                Status
            )
            VALUES
            (
                @RepFID,
                @ActorUserID,
                'Open'
            );

            SET @ResultID = SCOPE_IDENTITY();

            SET @Message =
                N'Purchase Request created. Replenishment remains pending for receiving.';
        END

        /* SAVE QUOTATION */

        ELSE IF @Action = 'SaveQuotation'
        BEGIN
            IF @PriceRaw IS NULL
               OR @PriceRaw < 0
               OR @PriceRaw > 99999999.99
               OR @PriceRaw <> ROUND(@PriceRaw, 2)
                THROW 50505,
                    'Enter a valid unit price with at most two decimal places.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID
                  AND Status IN ('Open', 'Pending Approval')
            )
                THROW 50506,
                    'This PR is not open for quotations.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507,
                    'Quotations cannot change while this PR has an active PO.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIERS
                WHERE SupplierID = @SupplierID
                  AND IsActive = 1
            )
                THROW 50508,
                    'Select an active supplier.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID
            )
            AND
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) >= 3
                THROW 50509,
                    'Only three supplier quotations are allowed per PR.',
                    1;

            SET @Price = CONVERT(DECIMAL(10,2), @PriceRaw);

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID
            )
            BEGIN
                UPDATE dbo.SUPPLIER_QUOTATIONS
                SET
                    QuotedPrice = @Price,
                    DateQuoted = SYSDATETIME()
                WHERE PRID = @PRID
                  AND SupplierID = @SupplierID;
            END
            ELSE
            BEGIN
                INSERT INTO dbo.SUPPLIER_QUOTATIONS
                (
                    PRID,
                    SupplierID,
                    QuotedPrice,
                    IsRecommended
                )
                VALUES
                (
                    @PRID,
                    @SupplierID,
                    @Price,
                    0
                );
            END;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) = 1
            BEGIN
                UPDATE q
                SET IsRecommended = 1
                FROM dbo.SUPPLIER_QUOTATIONS q
                INNER JOIN dbo.SUPPLIERS s
                    ON s.SupplierID = q.SupplierID
                   AND s.IsActive = 1
                WHERE q.PRID = @PRID;

                SET @Message =
                    N'Quotation saved. The only active supplier is recommended automatically.';
            END
            ELSE
            BEGIN
                SET @Message =
                    N'Quotation saved. Compare again before creating a PO.';
            END;
        END

        /* COMPARE AND RECOMMEND */

        ELSE IF @Action = 'Recommend'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
                WHERE PRID = @PRID
                  AND Status = 'Open'
            )
                THROW 50506,
                    'Select an open PR for comparison.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509,
                    'Please select a supplier first and save one to three quotations.',
                    1;

            SELECT TOP (1)
                @QuotationID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND s.IsActive = 1
            ORDER BY
                q.QuotedPrice,
                q.QuotationID;

            IF @QuotationID IS NULL
                THROW 50508,
                    'No quotation from an active supplier is available.',
                    1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 1
            WHERE QuotationID = @QuotationID;

            SET @ResultID = @QuotationID;

            SET @Message =
                N'Lowest-priced active supplier recommended.';
        END

        /* CREATE PO */

        ELSE IF @Action = 'CreatePO'
        BEGIN
            SELECT @RepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
              AND Status = 'Open';

            IF @RepFID IS NULL
                THROW 50506,
                    'Select an open Purchase Request.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507,
                    'This PR already has an active PO.',
                    1;

            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            SET @Remaining = @Needed - @Received;

            IF @Status <> 'Pending'
               OR @Remaining IS NULL
               OR @Remaining <= 0
                THROW 50503,
                    'This replenishment no longer needs purchasing.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509,
                    'Please select a supplier first and save one to three quotations.',
                    1;

            SELECT TOP (1)
                @WinnerID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND s.IsActive = 1
            ORDER BY
                q.QuotedPrice,
                q.QuotationID;

            IF @WinnerID IS NULL
                THROW 50508,
                    'Please select an active supplier and save its quotation first.',
                    1;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) = 1
            BEGIN
                UPDATE dbo.SUPPLIER_QUOTATIONS
                SET IsRecommended = 1
                WHERE PRID = @PRID
                  AND QuotationID = @WinnerID;
            END;

            SELECT
                @QuotationID = q.QuotationID,
                @SupplierID = q.SupplierID,
                @Price = q.QuotedPrice
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND q.IsRecommended = 1
              AND s.IsActive = 1;

            IF @QuotationID IS NULL
               OR @QuotationID <> @WinnerID
                THROW 50511,
                    'Compare quotations again before creating the PO.',
                    1;

            IF @ExpectedDate IS NULL
               OR @ExpectedDate < CAST(SYSDATETIME() AS DATE)
                THROW 50510,
                    'Choose an expected delivery date of today or later.',
                    1;

            IF CONVERT(DECIMAL(20,2), @Remaining) * @Price
               > 9999999999.99
                THROW 50512,
                    'The PO amount exceeds the supported amount.',
                    1;

            SET @Total = @Remaining * @Price;
            SET @Year = YEAR(SYSDATETIME());

            SELECT @Budget = BudgetAmount
            FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
            WHERE BudgetYear = @Year
              AND IsActive = 1;

            SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE YEAR(DateIssued) = @Year
              AND Status IN
              (
                  'Approved',
                  'Sent to Supplier',
                  'Partially Delivered',
                  'Delivered'
              );

            IF @Budget IS NULL
               OR @Committed + @Total > @Budget
                THROW 50513,
                    'Configure a sufficient annual budget first.',
                    1;

            INSERT INTO dbo.PURCHASE_ORDERS
            (
                PRID,
                SupplierID,
                QuantityOrdered,
                UnitPrice,
                TotalAmount,
                Status
            )
            VALUES
            (
                @PRID,
                @SupplierID,
                @Remaining,
                @Price,
                @Total,
                'Pending Approval'
            );

            SET @POID = SCOPE_IDENTITY();
            SET @ResultID = @POID;

            INSERT INTO dbo.PO_PR_Mapping
            (
                POID,
                PRID
            )
            VALUES
            (
                @POID,
                @PRID
            );

            INSERT INTO dbo.PURCHASING_PO_TRACKING
            (
                POID,
                ExpectedDate,
                ReceivedBeforeOrder
            )
            VALUES
            (
                @POID,
                @ExpectedDate,
                @Received
            );

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Pending Approval'
            WHERE PRID = @PRID;

            SET @Message =
                N'PO created for the remaining quantity and awaiting approval.';
        END

        /* SET BUDGET */

        ELSE IF @Action = 'SetBudget'
        BEGIN
            IF @Year IS NULL
               OR @Year NOT BETWEEN 2000 AND 2100
               OR @AmountRaw IS NULL
               OR @AmountRaw < 0
               OR @AmountRaw > 999999999999.99
               OR @AmountRaw <> ROUND(@AmountRaw, 2)
                THROW 50514,
                    'Enter a valid budget year and amount.',
                    1;

            DECLARE @BudgetInput DECIMAL(14,2) =
                CONVERT(DECIMAL(14,2), @AmountRaw);

            EXEC dbo.usp_Purchasing_SetBudget
                @Year,
                @BudgetInput,
                @ActorUserID;

            SET @Message = N'Annual budget saved.';
        END

        /* APPROVE PO */

        ELSE IF @Action = 'ApprovePO'
        BEGIN
            EXEC dbo.usp_Purchasing_ApprovePO
                @POID,
                @ActorUserID;

            SET @Message = N'PO approved.';
        END

        /* REJECT PO (WITH MAKER-CHECKER GUARD) */

        ELSE IF @Action = 'RejectPO'
        BEGIN
            IF @Notes IS NULL
                THROW 50515,
                    'A rejection reason is required.',
                    1;

            DECLARE @RejectPOCreatorID INT = COALESCE(
                (
                    SELECT TOP (1) ds.SignerUserID
                    FROM dbo.DOCUMENT_SIGNATURES ds
                    WHERE ds.DocumentType = 'PURCHASE_ORDER'
                      AND ds.DocumentID = @POID
                      AND ds.Stage = 'Requested'
                      AND ds.IsActive = 1
                    ORDER BY ds.SignatureID DESC
                ),
                (
                    SELECT pr.CreatedByUserID
                    FROM dbo.PURCHASE_ORDERS po
                    INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
                    WHERE po.POID = @POID
                )
            );

            IF @RejectPOCreatorID = @ActorUserID
                THROW 50527,
                    'You cannot reject your own purchase order. Another authorized approver must review it.',
                    1;

            UPDATE dbo.PURCHASE_ORDERS
            SET Status = 'Rejected'
            WHERE POID = @POID
              AND Status = 'Pending Approval';

            IF @@ROWCOUNT <> 1
                THROW 50516,
                    'Only a pending PO can be rejected.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_PO_TRACKING
                WHERE POID = @POID
            )
            BEGIN
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);
            END;

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DecisionReason = @Notes
            WHERE POID = @POID;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Rejected'
            WHERE PRID =
            (
                SELECT PRID
                FROM dbo.PURCHASE_ORDERS
                WHERE POID = @POID
            )
            OR PRID IN
            (
                SELECT PRID
                FROM dbo.PO_PR_Mapping
                WHERE POID = @POID
            );

            INSERT INTO dbo.NOTIFICATIONS
            (
                RecipientUserID,
                NotificationType,
                Title,
                Message,
                RelatedEntityType,
                RelatedEntityID,
                IsRead,
                CreatedAt
            )
            SELECT DISTINCT
                pr.CreatedByUserID,
                'PO_REJECTED',
                'Purchase order rejected',
                @Notes,
                'PURCHASE_ORDER',
                @POID,
                0,
                SYSDATETIME()
            FROM dbo.PURCHASE_REQUESTS pr
            WHERE pr.PRID =
            (
                SELECT PRID
                FROM dbo.PURCHASE_ORDERS
                WHERE POID = @POID
            )
            OR pr.PRID IN
            (
                SELECT PRID
                FROM dbo.PO_PR_Mapping
                WHERE POID = @POID
            );

            SET @Message =
                N'PO rejected and Purchasing notified.';
        END

        /* REOPEN REJECTED PR */

        ELSE IF @Action = 'RevisePR'
        BEGIN
            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1
                          FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID
                            AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50517,
                    'A PR with an active PO cannot be reopened.',
                    1;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Open'
            WHERE PRID = @PRID
              AND Status = 'Rejected';

            IF @@ROWCOUNT <> 1
                THROW 50517,
                    'Only a rejected PR can be reopened.',
                    1;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            SET @Message =
                N'PR reopened. Update quotations and compare again.';
        END

        /* MARK PO AS SENT TO SUPPLIER */

        ELSE IF @Action = 'DispatchPO'
        BEGIN
            UPDATE po
            SET Status = 'Sent to Supplier'
            FROM dbo.PURCHASE_ORDERS po
            INNER JOIN dbo.SUPPLIERS s
                ON s.SupplierID = po.SupplierID
            WHERE po.POID = @POID
              AND po.Status = 'Approved'
              AND s.IsActive = 1;

            IF @@ROWCOUNT <> 1
                THROW 50518,
                    'Only an approved PO for an active supplier can be dispatched.',
                    1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_PO_TRACKING
                WHERE POID = @POID
            )
            BEGIN
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);
            END;

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DispatchedAt = SYSDATETIME()
            WHERE POID = @POID;

            SET @Message =
                N'Supplier dispatch recorded.';
        END

        /* RECORD DELIVERY CHECK OR REPLACEMENT DELIVERY */

        ELSE IF @Action = 'RecordDR'
        BEGIN
            SELECT
                @ItemID = ItemID,
                @Outstanding = OutstandingQuantity,
                @Status = Status
            FROM dbo.vw_PurchasingWorkspacePO
            WHERE POID = @POID;

            IF @Status IS NULL
               OR @Status NOT IN
               (
                   'Sent to Supplier',
                   'Partially Delivered'
               )
                THROW 50519,
                    'Select a dispatched PO with outstanding quantities.',
                    1;

            IF @DRNumber IS NULL
                THROW 50520,
                    'Enter the supplier DR number.',
                    1;

            IF @Delivered IS NULL
               OR @Accepted IS NULL
               OR @Rejected IS NULL
               OR @Delivered <= 0
               OR @Accepted < 0
               OR @Rejected < 0
               OR CONVERT(BIGINT, @Accepted) + @Rejected <> @Delivered
               OR @Accepted > @Outstanding
                THROW 50521,
                    'Check delivered, accepted, rejected, and outstanding quantities.',
                    1;

            IF @Rejected > 0 AND @Notes IS NULL
                THROW 50522,
                    'Describe the damaged or rejected items.',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.PURCHASING_DR_TRACKING
                WHERE POID = @POID
                  AND SupplierDRNumber = @DRNumber
            )
                THROW 50523,
                    'That supplier DR is already recorded for this PO.',
                    1;

            INSERT INTO dbo.DELIVERY_RECEIPTS
            (
                POID,
                Status,
                Notes
            )
            VALUES
            (
                @POID,
                CASE
                    WHEN @Accepted = 0
                        THEN 'Rejected'
                    WHEN @Rejected > 0
                        THEN 'With Discrepancies'
                    ELSE 'Accepted'
                END,
                @Notes
            );

            SET @DRID = SCOPE_IDENTITY();
            SET @ResultID = @DRID;

            INSERT INTO dbo.DELIVERY_RECEIPT_DETAILS
            (
                DRID,
                ItemID,
                QuantityDelivered,
                QuantityAccepted,
                QuantityRejected,
                Remarks
            )
            VALUES
            (
                @DRID,
                @ItemID,
                @Delivered,
                @Accepted,
                @Rejected,
                LEFT(@Notes, 500)
            );

            INSERT INTO dbo.PURCHASING_DR_TRACKING
            (
                DRID,
                POID,
                SupplierDRNumber,
                RecordedByUserID
            )
            VALUES
            (
                @DRID,
                @POID,
                @DRNumber,
                @ActorUserID
            );

            INSERT INTO dbo.NOTIFICATIONS
            (
                RecipientUserID,
                NotificationType,
                Title,
                Message,
                RelatedEntityType,
                RelatedEntityID,
                IsRead,
                CreatedAt
            )
            SELECT DISTINCT
                u.UserID,
                'PURCHASE_DELIVERY',
                'Supplier delivery checked',
                CONCAT
                (
                    'PO #', @POID,
                    ', DR #', @DRID,
                    ': ', @Accepted,
                    ' accepted. Process this checked DR through Receiving.'
                ),
                'DELIVERY_RECEIPT',
                @DRID,
                0,
                SYSDATETIME()
            FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp
                ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p
                ON p.PermissionID = rp.PermissionID
            WHERE u.IsActive = 1
              AND p.PermissionCode = 'receiving.manage'
              AND @Accepted > 0;

            SET @Message =
                N'DR recorded. Accepted items await checked-DR receiving.';
        END

        /* RECORD THAT A REPLACEMENT WAS REQUESTED */

        ELSE IF @Action = 'ReplacementSent'
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.DELIVERY_RECEIPT_DETAILS
                WHERE DRID = @DRID
                  AND QuantityRejected > 0
            )
                THROW 50524,
                    'This DR has no rejected items.',
                    1;

            UPDATE dbo.PURCHASING_DR_TRACKING
            SET ReplacementRequestedAt = SYSDATETIME()
            WHERE DRID = @DRID
              AND ReplacementRequestedAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50524,
                    'Replacement request already recorded or DR unavailable.',
                    1;

            SET @Message =
                N'Supplier replacement request recorded.';
        END

        /* RECORD THAT A FOLLOW-UP WAS SENT */

        ELSE IF @Action = 'FollowupSent'
        BEGIN
            UPDATE dbo.PURCHASING_FOLLOWUPS
            SET
                SentAt = SYSDATETIME(),
                SentByUserID = @ActorUserID
            WHERE FollowupID = @FollowupID
              AND SentAt IS NULL;

            IF @@ROWCOUNT <> 1
                THROW 50525,
                    'Follow-up already marked sent or unavailable.',
                    1;

            SET @Message =
                N'Follow-up marked sent.';
        END
        ELSE
        BEGIN
            ;THROW 50526,
                'Unknown purchasing action.',
                1;
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
            'PURCHASING_ACTION',
            CONCAT
            (
                @Action,
                '; PR=', @PRID,
                '; PO=', @POID,
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

CREATE   PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithDeliveryReference
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

/* =========================================================
   7. PURCHASING ACTION WRAPPER
      - CreatePO: explicit supplier + manager notification
      - RejectPO: return requisition for revision (when safe)
      - RecordDR: record + receive stock + allocate immediately
   ========================================================= */

CREATE   PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithFlowAlignment
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@Payload) <> 1
        THROW 50500, 'Invalid purchasing request.', 1;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = N'purchasing.manage'
    )
        SET @Manage = 1;

    SELECT
        @Approve = CASE
            WHEN r.RoleName IN (N'Admin', N'Manager') THEN 1 ELSE 0 END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    DECLARE
        @PRID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID')),
        @POID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.poID')),
        @RepFID INT,
        @SupplierID INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.supplierID')),
        @ExpectedDate DATE = TRY_CONVERT(DATE, JSON_VALUE(@Payload, '$.expectedDate')),
        @Needed INT,
        @Received INT,
        @Remaining INT,
        @Status VARCHAR(30),
        @QuotationID INT,
        @RecommendedID INT,
        @WinnerID INT,
        @Price DECIMAL(10,2),
        @Total DECIMAL(12,2),
        @Budget DECIMAL(14,2),
        @Committed DECIMAL(14,2),
        @Year INT,
        @Message NVARCHAR(300) = N'Purchasing action completed.',
        @ResultID INT,
        @RequisitionID INT,
        @DRID INT,
        @DeliveryReference NVARCHAR(100);

    DECLARE @Notes NVARCHAR(1000) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@Payload, '$.notes'))), '');

    IF LEN(@Notes) > 1000
        THROW 50500, 'Notes must be 1000 characters or fewer.', 1;

    IF @Action = 'CreatePO'
    BEGIN
        IF @Manage = 0
            THROW 50501, 'Purchasing management permission is required.', 1;
    END
    ELSE IF @Action = 'RejectPO'
    BEGIN
        IF @Approve = 0
            THROW 50501, 'Only an Admin or Manager may decide a PO.', 1;
    END
    ELSE IF @Action = 'RecordDR'
    BEGIN
        IF @Manage = 0
            THROW 50501, 'Purchasing management permission is required.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Action = 'CreatePO'
        BEGIN
            SELECT @RepFID = RepFID
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID AND Status = 'Open';

            IF @RepFID IS NULL
                THROW 50506, 'Select an open Purchase Request.', 1;

            IF EXISTS
            (
                SELECT 1 FROM dbo.PURCHASE_ORDERS po
                WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                  AND
                  (
                      po.PRID = @PRID
                      OR EXISTS
                      (
                          SELECT 1 FROM dbo.PO_PR_Mapping m
                          WHERE m.POID = po.POID AND m.PRID = @PRID
                      )
                  )
            )
                THROW 50507, 'This PR already has an active PO.', 1;

            SELECT
                @Needed = QuantityNeeded,
                @Received = QuantityReceived,
                @Status = Status
            FROM dbo.REPLENISHMENT_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE RepFID = @RepFID;

            SET @Remaining = @Needed - @Received;

            IF @Status <> 'Pending' OR @Remaining IS NULL OR @Remaining <= 0
                THROW 50503, 'This replenishment no longer needs purchasing.', 1;

            IF
            (
                SELECT COUNT(*) FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) NOT BETWEEN 1 AND 3
                THROW 50509, 'Record one to three quotations first.', 1;

            SELECT TOP (1)
                @WinnerID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID AND s.IsActive = 1
            ORDER BY q.QuotedPrice, q.QuotationID;

            SELECT @RecommendedID = q.QuotationID
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND q.IsRecommended = 1
              AND s.IsActive = 1;

            IF @RecommendedID IS NULL OR @RecommendedID <> @WinnerID
                THROW 50511, 'Compare quotations again before creating the PO.', 1;

            -- Kani nga check kay ang gipili nga supplier dapat naay
            -- active quotation sa maong PR.
            SELECT
                @QuotationID = q.QuotationID,
                @Price = q.QuotedPrice
            FROM dbo.SUPPLIER_QUOTATIONS q
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
            WHERE q.PRID = @PRID
              AND q.SupplierID = @SupplierID
              AND s.IsActive = 1;

            IF @QuotationID IS NULL
                THROW 50536, 'Select a supplier with an active quotation.', 1;

            IF CONVERT(DECIMAL(20,2), @Remaining) * @Price > 9999999999.99
                THROW 50512, 'The PO amount exceeds the supported amount.', 1;

            SET @Total = @Remaining * @Price;
            SET @Year = YEAR(SYSDATETIME());

            SELECT @Budget = BudgetAmount
            FROM dbo.PURCHASE_BUDGETS WITH (UPDLOCK, HOLDLOCK)
            WHERE BudgetYear = @Year AND IsActive = 1;

            SELECT @Committed = ISNULL(SUM(TotalAmount), 0)
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE YEAR(DateIssued) = @Year
              AND Status IN
              (
                  'Approved', 'Sent to Supplier',
                  'Partially Delivered', 'Delivered'
              );

            IF @Budget IS NULL OR @Committed + @Total > @Budget
                THROW 50513, 'Configure a sufficient annual budget first.', 1;

            INSERT INTO dbo.PURCHASE_ORDERS
                (PRID, SupplierID, QuantityOrdered, UnitPrice, TotalAmount, Status)
            VALUES
                (@PRID, @SupplierID, @Remaining, @Price, @Total, 'Pending Approval');

            SET @POID = SCOPE_IDENTITY();
            SET @ResultID = @POID;

            INSERT INTO dbo.PO_PR_Mapping (POID, PRID)
            VALUES (@POID, @PRID);

            INSERT INTO dbo.PURCHASING_PO_TRACKING
                (POID, ExpectedDate, ReceivedBeforeOrder)
            VALUES
                (@POID, @ExpectedDate, @Received);

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Pending Approval'
            WHERE PRID = @PRID;

            -- Kani nga notification kay para sa Manager/Admin nga
            -- mo-review sa bag-ong PO.
            INSERT INTO dbo.NOTIFICATIONS
                (RecipientUserID, NotificationType, Title, Message,
                 RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
            SELECT DISTINCT
                u.UserID, 'PO_PENDING_APPROVAL', 'Purchase order awaiting approval',
                CONCAT('PO #', @POID, ' for PR #', @PRID,
                       ' is awaiting your approval.'),
                'PURCHASE_ORDER', @POID, 0, SYSDATETIME()
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
            WHERE u.IsActive = 1
              AND r.IsActive = 1
              AND r.RoleName IN (N'Admin', N'Manager')
              AND u.UserID <> @ActorUserID;

            SET @Message = N'PO created for the remaining quantity and awaiting approval.';
        END
        ELSE IF @Action = 'RejectPO'
        BEGIN
            IF @Notes IS NULL
                THROW 50515, 'A rejection reason is required.', 1;

            SELECT @PRID = PRID
            FROM dbo.PURCHASE_ORDERS WITH (UPDLOCK, HOLDLOCK)
            WHERE POID = @POID AND Status = 'Pending Approval';

            IF @PRID IS NULL
                THROW 50516, 'Only a pending PO can be rejected.', 1;

            UPDATE dbo.PURCHASE_ORDERS
            SET Status = 'Rejected'
            WHERE POID = @POID AND Status = 'Pending Approval';

            IF NOT EXISTS
            (
                SELECT 1 FROM dbo.PURCHASING_PO_TRACKING WHERE POID = @POID
            )
                INSERT INTO dbo.PURCHASING_PO_TRACKING (POID)
                VALUES (@POID);

            UPDATE dbo.PURCHASING_PO_TRACKING
            SET DecisionReason = @Notes WHERE POID = @POID;

            UPDATE dbo.PURCHASE_REQUESTS
            SET Status = 'Rejected'
            WHERE PRID = @PRID
               OR PRID IN (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID);

            INSERT INTO dbo.NOTIFICATIONS
                (RecipientUserID, NotificationType, Title, Message,
                 RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
            SELECT DISTINCT
                pr.CreatedByUserID, 'PO_REJECTED',
                'Purchase order rejected', @Notes,
                'PURCHASE_ORDER', @POID, 0, SYSDATETIME()
            FROM dbo.PURCHASE_REQUESTS pr
            WHERE pr.PRID = @PRID
               OR pr.PRID IN (SELECT PRID FROM dbo.PO_PR_Mapping WHERE POID = @POID);

            UPDATE dbo.NOTIFICATIONS
            SET IsRead = 1, ReadAt = SYSDATETIME()
            WHERE NotificationType = 'PO_PENDING_APPROVAL'
              AND RelatedEntityType = 'PURCHASE_ORDER'
              AND RelatedEntityID = @POID
              AND IsRead = 0;

            SELECT TOP (1)
                @RequisitionID = rr.OriginRequisitionID
            FROM dbo.PURCHASE_REQUESTS pr
            INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
            WHERE pr.PRID = @PRID;

            -- Kani nga block kay mo-balik sa requisition ngadto sa
            -- Rejected aron makita ang Revise button sa Requisition
            -- History. Safe ra kung walay laing active PO, walay
            -- nadawat, ug walay fully allocated nga detail.
            IF @RequisitionID IS NOT NULL
               AND EXISTS
               (
                   SELECT 1 FROM dbo.REQUISITIONS
                   WHERE RequisitionID = @RequisitionID AND Status = 'Approved'
               )
               AND NOT EXISTS
               (
                   SELECT 1
                   FROM dbo.REPLENISHMENT_REQUESTS rr
                   INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.RepFID = rr.RepFID
                   INNER JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
                   WHERE rr.OriginRequisitionID = @RequisitionID
                     AND po.POID <> @POID
                     AND po.Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered')
               )
               AND NOT EXISTS
               (
                   SELECT 1 FROM dbo.REPLENISHMENT_REQUESTS
                   WHERE OriginRequisitionID = @RequisitionID
                     AND QuantityReceived > 0
               )
               AND NOT EXISTS
               (
                   SELECT 1 FROM dbo.REQUISITION_DETAILS
                   WHERE RequisitionID = @RequisitionID
                     AND Status = 'Approved'
               )
            BEGIN
                EXEC dbo.usp_Requisition_ReleaseForRevision
                    @RequisitionID = @RequisitionID,
                    @ActorUserID = @ActorUserID;

                UPDATE dbo.REQUISITIONS
                SET Status = 'Rejected',
                    RejectionReason = CONCAT('Purchase order rejected: ', COALESCE(@Notes, '')),
                    ArchivedAt = NULL
                WHERE RequisitionID = @RequisitionID
                  AND Status = 'Approved';

                UPDATE dbo.REQUISITION_DETAILS
                SET Status = 'Rejected'
                WHERE RequisitionID = @RequisitionID
                  AND Status IN ('Pending', 'Partially Fulfilled');

                SET @Message = N'PO rejected. The requisition was returned to the requestor for revision.';
            END
            ELSE
                SET @Message = N'PO rejected and Purchasing notified.';
        END
        ELSE IF @Action = 'RecordDR'
        BEGIN
            DECLARE @RecordResult TABLE
            (
                ID INT,
                Message NVARCHAR(300),
                DeliveryReference NVARCHAR(100)
            );

            INSERT INTO @RecordResult (ID, Message, DeliveryReference)
            EXEC dbo.usp_PurchasingWorkspace_ActionWithDeliveryReference
                @ActorUserID = @ActorUserID,
                @Action = @Action,
                @Payload = @Payload;

            SELECT
                @DRID = ID,
                @Message = Message,
                @DeliveryReference = DeliveryReference
            FROM @RecordResult;

            IF @DRID IS NOT NULL
               AND EXISTS
               (
                   SELECT 1 FROM dbo.DELIVERY_RECEIPT_DETAILS
                   WHERE DRID = @DRID AND QuantityAccepted > 0
               )
            BEGIN
                -- Kani nga call kay dayon mo-update sa stock ug
                -- mo-allocate sa naghuwat nga requisitions.
                EXEC dbo.usp_Purchasing_ReceiveCheckedDR
                    @ActorUserID = @ActorUserID,
                    @DRID = @DRID;

                UPDATE @RecordResult
                SET Message = N'DR recorded and accepted items were added to stock.'
                WHERE ID = @DRID;
            END;

            COMMIT TRANSACTION;

            SELECT ID, Message, DeliveryReference FROM @RecordResult;
            RETURN;
        END
        ELSE
        BEGIN
            EXEC dbo.usp_PurchasingWorkspace_ActionWithDeliveryReference
                @ActorUserID = @ActorUserID,
                @Action = @Action,
                @Payload = @Payload;

            COMMIT TRANSACTION;
            RETURN;
        END;

        INSERT INTO dbo.USER_AUDIT_LOGS
            (ActorUserID, TargetUserID, ActionType, Description)
        VALUES
            (@ActorUserID, @ActorUserID, 'PURCHASING_ACTION',
             CONCAT(@Action, '; PR=', @PRID, '; PO=', @POID, '; ', @Message));

        COMMIT TRANSACTION;

        SELECT @ResultID AS ID, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   6. PR AND QUOTATION REMOVAL
   ============================================================ */

CREATE   PROCEDURE dbo.usp_PurchasingWorkspace_ActionWithRemoval
    @ActorUserID INT,
    @Action VARCHAR(30),
    @Payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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
        THROW 50600,
            'Invalid purchasing request.',
            1;

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
            'Purchasing management permission is required.',
            1;

    DECLARE @PRID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.prID'));

    DECLARE @QuotationID INT =
        TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.quotationID'));

    DECLARE @LockResult INT;
    DECLARE @ResultID INT;
    DECLARE @Message NVARCHAR(300);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PurchasingWorkspace',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50602,
                'Purchasing is busy. Please try again.',
                1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            SET @PRID = NULL;

            SELECT @PRID = PRID
            FROM dbo.SUPPLIER_QUOTATIONS WITH (UPDLOCK, HOLDLOCK)
            WHERE QuotationID = @QuotationID;

            IF @PRID IS NULL
                THROW 50603,
                    'This quotation no longer exists.',
                    1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.PURCHASE_REQUESTS WITH (UPDLOCK, HOLDLOCK)
            WHERE PRID = @PRID
              AND Status = 'Open'
        )
            THROW 50604,
                'Only an open Purchase Request can be changed.',
                1;

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
                'Records with Purchase Order history cannot be removed.',
                1;

        IF @Action = 'RemoveQuotation'
        BEGIN
            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE QuotationID = @QuotationID
              AND PRID = @PRID;

            UPDATE dbo.SUPPLIER_QUOTATIONS
            SET IsRecommended = 0
            WHERE PRID = @PRID;

            SET @ResultID = @QuotationID;

            IF
            (
                SELECT COUNT(*)
                FROM dbo.SUPPLIER_QUOTATIONS
                WHERE PRID = @PRID
            ) = 1
            BEGIN
                UPDATE q
                SET IsRecommended = 1
                FROM dbo.SUPPLIER_QUOTATIONS q
                INNER JOIN dbo.SUPPLIERS supplier
                    ON supplier.SupplierID = q.SupplierID
                   AND supplier.IsActive = 1
                WHERE q.PRID = @PRID;

                SET @Message =
                    N'Quotation removed. The remaining active supplier is recommended automatically.';
            END
            ELSE
            BEGIN
                SET @Message =
                    N'Quotation removed. Compare the remaining quotations again.';
            END;
        END
        ELSE
        BEGIN
            DECLARE @RemovedRepFID INT =
            (
                SELECT RepFID
                FROM dbo.PURCHASE_REQUESTS
                WHERE PRID = @PRID
            );

            DELETE FROM dbo.SUPPLIER_QUOTATIONS
            WHERE PRID = @PRID;

            DELETE FROM dbo.PURCHASE_REQUESTS
            WHERE PRID = @PRID;

            SET @ResultID = @PRID;

            SET @Message =
                N'Purchase Request and its quotations removed.';
        END;

        IF @Action = 'RemovePR'
        BEGIN
            DECLARE @CancelledOrigin INT =
            (
                SELECT rr.OriginRequisitionID
                FROM dbo.REPLENISHMENT_REQUESTS rr
                INNER JOIN dbo.REQUISITIONS rq
                    ON rq.RequisitionID = rr.OriginRequisitionID
                WHERE rr.RepFID = @RemovedRepFID
                  AND rq.Status = 'Cancelled'
            );

            IF @CancelledOrigin IS NOT NULL
            BEGIN
                EXEC dbo.usp_Purchasing_ReconcileCancelledDemand
                    @RequisitionID = @CancelledOrigin;
            END;
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
            'PURCHASING_ACTION',
            CONCAT
            (
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

/* ============================================================
   6. PURCHASING WORKSPACE LOAD â€” PERMISSION-BASED FLAGS
   ============================================================ */

CREATE   PROCEDURE dbo.usp_PurchasingWorkspace_Load
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Manage BIT = 0;
    DECLARE @Approve BIT = 0;
    DECLARE @Admin BIT = 0;
    DECLARE @IsStaff BIT = 0;

    SELECT
        @IsStaff =
            CASE
                WHEN r.RoleName = N'Staff' THEN 1
                ELSE 0
            END
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1
      AND r.IsActive = 1;

    IF @IsStaff = 0
       AND NOT EXISTS
       (
           SELECT 1
           FROM dbo.USERS u
           INNER JOIN dbo.ROLES r
               ON r.RoleID = u.RoleID
              AND r.IsActive = 1
           INNER JOIN dbo.ROLE_PERMISSIONS rp
               ON rp.RoleID = u.RoleID
           INNER JOIN dbo.PERMISSIONS p
               ON p.PermissionID = rp.PermissionID
           WHERE u.UserID = @ActorUserID
             AND u.IsActive = 1
             AND p.PermissionCode IN
             (
                 N'purchasing.view',
                 N'purchasing.manage'
             )
       )
        THROW 50501,
            'You do not have permission to view Purchasing.',
            1;

    SELECT
        @Manage = MAX(CASE WHEN p.PermissionCode = N'purchasing.manage' THEN 1 ELSE 0 END),
        @Approve = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END),
        @Admin = MAX(CASE WHEN p.PermissionCode = N'settings.manage' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SET @Manage = ISNULL(@Manage, 0);
    SET @Approve = ISNULL(@Approve, 0);
    SET @Admin = ISNULL(@Admin, 0);

    IF @Manage = 1
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @LockResult INT;

            EXEC @LockResult = sys.sp_getapplock
                @Resource = N'PurchasingWorkspace',
                @LockMode = 'Exclusive',
                @LockOwner = 'Transaction',
                @LockTimeout = 10000;

            IF @LockResult < 0
                THROW 50502,
                    'Purchasing is busy. Please refresh again.',
                    1;

            INSERT INTO dbo.PURCHASING_FOLLOWUPS
            (
                POID,
                ReminderDate,
                Message
            )
            SELECT
                po.POID,
                CAST(SYSDATETIME() AS DATE),
                CONCAT
                (
                    'Please follow up PO #', po.POID,
                    ' for ', po.ItemName,
                    '. Outstanding supplier quantity: ',
                    po.OutstandingQuantity,
                    '. Expected date: ',
                    CONVERT(VARCHAR(10), po.ExpectedDate, 23),
                    '.'
                )
            FROM dbo.vw_PurchasingWorkspacePO po
            WHERE po.Status IN
            (
                'Sent to Supplier',
                'Partially Delivered'
            )
              AND po.OutstandingQuantity > 0
              AND po.ExpectedDate <= CAST(SYSDATETIME() AS DATE)
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.PURCHASING_FOLLOWUPS f
                  WHERE f.POID = po.POID
                    AND f.ReminderDate =
                        CAST(SYSDATETIME() AS DATE)
              );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;
        END CATCH;
    END;

    /* Result 1: permissions */

    SELECT
        @Manage AS CanManage,
        @Approve AS CanApprove,
        @Admin AS CanSetBudget;

    /* Result 2: pending replenishments without a PR */

    SELECT
        rr.RepFID,
        i.ItemCode,
        i.ItemName,
        rr.QuantityNeeded - rr.QuantityReceived AS QuantityNeeded,
        rr.QuantityReceived,
        rr.OriginRequisitionID
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    WHERE rr.Status = 'Pending'
      AND rr.QuantityNeeded > rr.QuantityReceived
      AND
      (
          @IsStaff = 0
          OR EXISTS
          (
              SELECT 1
              FROM dbo.REQUISITIONS rq
              WHERE rq.RequisitionID = rr.OriginRequisitionID
                AND rq.RequestorUserID = @ActorUserID
          )
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.REQUISITIONS rq
          WHERE rq.RequisitionID = rr.OriginRequisitionID
            AND rq.Status = 'Cancelled'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.PURCHASE_REQUESTS pr
          WHERE pr.RepFID = rr.RepFID
      )
    ORDER BY
        rr.DateGenerated,
        rr.RepFID;

    /* Result 3: purchase requests */

    SELECT
        pr.PRID,
        pr.RepFID,
        i.ItemCode,
        i.ItemName,
        CASE
            WHEN rr.QuantityNeeded > rr.QuantityReceived
                THEN rr.QuantityNeeded - rr.QuantityReceived
            ELSE 0
        END AS QuantityNeeded,
        rr.QuantityNeeded AS OriginalQuantityNeeded,
        rr.QuantityReceived,
        rr.OriginRequisitionID,
        pr.Status,
        CAST
        (
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM dbo.REQUISITIONS rq
                    WHERE rq.RequisitionID = rr.OriginRequisitionID
                      AND rq.Status = 'Cancelled'
                )
                    THEN 1
                ELSE 0
            END
            AS BIT
        ) AS OriginCancelled,
        pr.DateCreated
    FROM dbo.PURCHASE_REQUESTS pr
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rr.ItemID
    WHERE @IsStaff = 0
    ORDER BY pr.PRID DESC;

    /* Result 4: supplier quotations */

    SELECT
        q.QuotationID,
        q.PRID,
        q.SupplierID,
        s.SupplierName,
        s.IsActive,
        q.QuotedPrice,
        q.IsRecommended
    FROM dbo.SUPPLIER_QUOTATIONS q
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = q.SupplierID
    WHERE @IsStaff = 0
    ORDER BY
        q.PRID,
        q.QuotedPrice,
        q.QuotationID;

    /* Result 5: suppliers */

    SELECT
        SupplierID,
        SupplierName,
        Email,
        IsActive
    FROM dbo.SUPPLIERS
    WHERE @IsStaff = 0
    ORDER BY SupplierName;

    /* Result 6: purchase orders */

    SELECT *
    FROM dbo.vw_PurchasingWorkspacePO
    WHERE @IsStaff = 0
    ORDER BY POID DESC;

    /* Result 7: budgets */

    SELECT
        b.BudgetYear,
        b.BudgetAmount,
        ISNULL(c.Committed, 0) AS Committed,
        b.BudgetAmount - ISNULL(c.Committed, 0) AS Remaining
    FROM dbo.PURCHASE_BUDGETS b
    OUTER APPLY
    (
        SELECT SUM(po.TotalAmount) AS Committed
        FROM dbo.PURCHASE_ORDERS po
        WHERE YEAR(po.DateIssued) = b.BudgetYear
          AND po.Status IN
          (
              'Approved',
              'Sent to Supplier',
              'Partially Delivered',
              'Delivered'
          )
    ) c
    WHERE b.IsActive = 1
      AND @IsStaff = 0
    ORDER BY b.BudgetYear DESC;

    /* Result 8: delivery checks and receiving status */

    SELECT
        dr.DRID,
        dr.POID,
        tr.SupplierDRNumber,
        dr.DeliveryDate,
        dr.Status,
        dr.Notes,
        d.QuantityDelivered,
        d.QuantityAccepted,
        d.QuantityRejected,
        rm.RMID,
        rm.InventoryUpdated,
        tr.ReplacementRequestedAt
    FROM dbo.DELIVERY_RECEIPTS dr
    LEFT JOIN dbo.PURCHASING_DR_TRACKING tr
        ON tr.DRID = dr.DRID
    LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS d
        ON d.DRID = dr.DRID
    LEFT JOIN dbo.RECEIVING_MEMOS rm
        ON rm.DRID = dr.DRID
    WHERE @IsStaff = 0
    ORDER BY dr.DRID DESC;

    /* Result 9: follow-up drafts */

    SELECT
        f.*,
        s.SupplierName,
        s.Email
    FROM dbo.PURCHASING_FOLLOWUPS f
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.POID = f.POID
    INNER JOIN dbo.SUPPLIERS s
        ON s.SupplierID = po.SupplierID
    WHERE @IsStaff = 0
    ORDER BY f.FollowupID DESC;
END;
GO

-- Kani nga procedure para maghimo og receiving memo ug i-check ang items batok sa PO.
CREATE   PROCEDURE usp_Receiving_CreateRM
    @DRID INT,
    @ReceivedByUserID INT,
    @DetailsJson NVARCHAR(MAX),
    @Remarks NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@DetailsJson) <> 1
        THROW 50170, 'The JSON data for the received items is invalid.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @POID INT;
        SELECT @POID = dr.POID
        FROM DELIVERY_RECEIPTS dr WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN PURCHASE_ORDERS po ON po.POID = dr.POID
        WHERE dr.DRID = @DRID AND dr.Status <> 'Rejected'
          AND po.Status IN ('Approved', 'Sent to Supplier', 'Partially Delivered');

        IF @POID IS NULL
            THROW 50171, 'No valid delivery receipt or purchase order (PO) could be found.', 1;

        IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ReceivedByUserID AND IsActive = 1)
            THROW 50172, 'The receiver does not exist or is inactive.', 1;

        IF EXISTS (SELECT 1 FROM RECEIVING_MEMOS WHERE DRID = @DRID)
            THROW 50173, 'A receiving memo already exists for this delivery receipt.', 1;

        DECLARE @Details TABLE (ItemID INT PRIMARY KEY, QuantityReceived INT);
        INSERT INTO @Details (ItemID, QuantityReceived)
        SELECT TRY_CONVERT(INT, JSON_VALUE(value, '$.ItemID')),
               TRY_CONVERT(INT, JSON_VALUE(value, '$.QuantityReceived'))
        FROM OPENJSON(@DetailsJson);

        IF NOT EXISTS (SELECT 1 FROM @Details)
            THROW 50174, 'Received item details are required.', 1;

        IF EXISTS (SELECT 1 FROM @Details WHERE ItemID IS NULL OR QuantityReceived IS NULL OR QuantityReceived <= 0)
            THROW 50175, 'The item or received quantity is invalid.', 1;

        DECLARE @OrderedItemID INT;
        SELECT @OrderedItemID = rr.ItemID
        FROM PURCHASE_ORDERS po
        INNER JOIN PO_PR_Mapping map ON map.POID = po.POID
        INNER JOIN PURCHASE_REQUESTS pr ON pr.PRID = map.PRID
        INNER JOIN REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        WHERE po.POID = @POID;

        IF EXISTS (SELECT 1 FROM @Details d WHERE d.ItemID <> @OrderedItemID)
            THROW 50176, 'The received items must match the items in the purchase order (PO).', 1;

        DECLARE @AlreadyReceived INT = 0;
        SELECT @AlreadyReceived = ISNULL(SUM(rmd.QuantityReceived), 0)
        FROM RECEIVING_MEMO_DETAILS rmd
        INNER JOIN RECEIVING_MEMOS rm ON rm.RMID = rmd.RMID
        INNER JOIN DELIVERY_RECEIPTS dr ON dr.DRID = rm.DRID
        WHERE dr.POID = @POID;

        IF @AlreadyReceived + (SELECT SUM(QuantityReceived) FROM @Details) >
           (SELECT QuantityOrdered FROM PURCHASE_ORDERS WHERE POID = @POID)
            THROW 50177, 'The received quantity exceeds the quantity specified in the purchase order (PO).', 1;

        INSERT INTO RECEIVING_MEMOS (DRID, ReceivedByUserID, Remarks)
        VALUES (@DRID, @ReceivedByUserID, @Remarks);

        DECLARE @RMID INT = SCOPE_IDENTITY();

        INSERT INTO RECEIVING_MEMO_DETAILS (RMID, ItemID, QuantityReceived)
        SELECT @RMID, ItemID, QuantityReceived FROM @Details;

        COMMIT TRANSACTION;
        SELECT @RMID AS RMID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ----------------------------------------------------------------
   2. HISTORY - mga actual nga Stock In nga narecords na sa
      Receiving (ReferenceType RECEIVING o REPLENISHMENT ra -
      dili apil ang SEED/INITIAL kay dili man na tinuod nga
      receiving). Ang reference kay computed: RR-#### o RefP-####,
      walay fake numbers.
   ---------------------------------------------------------------- */
CREATE   PROCEDURE usp_Receiving_GetHistory
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
          AND p.PermissionCode = N'receiving.view'
    )
        THROW 50341, 'You do not have permission to view the receiving history.', 1;

    SELECT TOP (50) l.InventoryLogID, l.TransactionDate, i.ItemName, i.ItemCode,
           l.QuantityChange, l.PreviousQuantity, l.NewQuantity, l.Remarks,
           CONCAT(u.FirstName, ' ', u.LastName) AS UserName,
           CASE
               WHEN l.ReferenceType = 'RECEIVING' AND l.ReferenceID IS NOT NULL
                   THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                   THEN 'RefP-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
               ELSE NULL
           END AS ReferenceDisplay,
           CASE
               WHEN l.ReferenceType = 'REPLENISHMENT' THEN 'Replenishment'
               ELSE 'Manual receipt'
           END AS SourceDisplay
    FROM INVENTORY_LOGS l
    INNER JOIN ITEMS i ON i.ItemID = l.ItemID
    LEFT JOIN USERS u ON u.UserID = l.UserID
    WHERE l.TransactionType = 'Stock In'
      AND l.ReferenceType IN ('RECEIVING', 'REPLENISHMENT')
    ORDER BY l.TransactionDate DESC, l.InventoryLogID DESC;
END;
GO

/* ----------------------------------------------------------------
   3. ITEMS - active nga items nga may live stock para sa manual
      receiving ("Receive without reference" nga dalan). Usay
      receiving engine ra gihapon ang gamiton sa submit.
   ---------------------------------------------------------------- */
CREATE   PROCEDURE usp_Receiving_GetItems
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
          AND p.PermissionCode = N'receiving.view'
    )
        THROW 50342, 'You do not have permission to view the receiving items.', 1;

    SELECT i.ItemID, i.ItemCode, i.ItemName, i.UnitOfMeasure,
           inv.QuantityOnHand, (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable
    FROM ITEMS i
    INNER JOIN INVENTORY inv ON inv.ItemID = i.ItemID
    WHERE i.IsActive = 1
    ORDER BY i.ItemName ASC;
END;
GO

CREATE   PROCEDURE dbo.usp_Receiving_GetPending
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
          AND p.PermissionCode = N'receiving.view'
    )
        THROW 50340, 'You do not have permission to view the receiving queue.', 1;

    SELECT f.RepFID, f.ItemID, i.ItemCode, i.ItemName, i.UnitOfMeasure,
           f.QuantityNeeded, f.DateGenerated,
           inv.QuantityOnHand, (inv.QuantityOnHand - inv.QuantityReserved) AS QuantityAvailable,
           f.QuantityReceived
    FROM REPLENISHMENT_REQUESTS f
    INNER JOIN ITEMS i ON i.ItemID = f.ItemID
    INNER JOIN INVENTORY inv ON inv.ItemID = f.ItemID
    WHERE f.Status = 'Pending'
      -- Kani nga RepF naay PO nga naa na sa supplier: i-receive kini
      -- pinaagi sa Checked Supplier Deliveries, dili direkta.
      AND NOT EXISTS
      (
          SELECT 1
          FROM PURCHASE_REQUESTS pr
          INNER JOIN PURCHASE_ORDERS po ON po.PRID = pr.PRID
          WHERE pr.RepFID = f.RepFID
            AND po.Status IN ('Sent to Supplier', 'Partially Delivered')
      )
    ORDER BY f.DateGenerated ASC;
END;
GO

/* ============================================================
   3. RECEIVING REPORT PRINT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Receiving_GetPrint
    @ActorUserID INT,
    @InventoryLogID BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN ('receiving.view', 'receiving.manage')
    )
        THROW 50603,
            'You do not have permission to print receiving reports.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.INVENTORY_LOGS
        WHERE InventoryLogID = @InventoryLogID
          AND TransactionType = 'Stock In'
    )
        RETURN;

    SELECT
        l.InventoryLogID,
        l.TransactionDate,
        l.TransactionType,
        l.QuantityChange,
        l.PreviousQuantity,
        l.NewQuantity,
        l.Remarks,
        l.ReferenceType,
        l.ReferenceID,
        CASE
            WHEN l.ReferenceType = 'RECEIVING'
                 AND l.ReferenceID IS NOT NULL
                THEN 'RR-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            WHEN l.ReferenceType = 'REPLENISHMENT'
                 AND l.ReferenceID IS NOT NULL
                THEN 'RefP-' + RIGHT(
                    '0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
            ELSE NULL
        END AS ReferenceDisplay,
        CASE
            WHEN l.ReferenceType = 'REPLENISHMENT' THEN 'Replenishment'
            ELSE 'Manual receipt'
        END AS SourceDisplay,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        cat.CategoryName,
        LTRIM(RTRIM(CONCAT(
            receivedBy.FirstName, ' ', receivedBy.LastName
        ))) AS ReceivedByName,
        rr.RepFID,
        rr.DateGenerated,
        rr.QuantityNeeded,
        rr.QuantityReceived,
        rr.Status AS RepFStatus,
        rr.OriginRequisitionID,
        po.POID,
        po.POStatus,
        po.SupplierName,
        po.SupplierDRNumber,
        po.DeliveryDate,
        po.DeliveryNotes,
        po.QuantityDelivered,
        po.QuantityAccepted,
        po.QuantityRejected,
        inv.QuantityOnHand,
        inv.QuantityReserved,
        ISNULL(
            inv.QuantityOnHand - inv.QuantityReserved, 0
        ) AS QuantityAvailable,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline
    FROM dbo.INVENTORY_LOGS l
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = l.ItemID
    LEFT JOIN dbo.CATEGORIES cat
        ON cat.CategoryID = i.CategoryID
    LEFT JOIN dbo.USERS receivedBy
        ON receivedBy.UserID = l.UserID
    LEFT JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON l.ReferenceType = 'REPLENISHMENT'
       AND rr.RepFID = l.ReferenceID
    LEFT JOIN dbo.INVENTORY inv
        ON inv.ItemID = l.ItemID
    OUTER APPLY
    (
        SELECT TOP (1)
            po.POID,
            po.Status AS POStatus,
            s.SupplierName,
            tr.SupplierDRNumber,
            dr.DeliveryDate,
            dr.Notes AS DeliveryNotes,
            dd.QuantityDelivered,
            dd.QuantityAccepted,
            dd.QuantityRejected
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr
            ON pr.PRID = po.PRID
        INNER JOIN dbo.SUPPLIERS s
            ON s.SupplierID = po.SupplierID
        LEFT JOIN dbo.DELIVERY_RECEIPTS dr
            ON dr.POID = po.POID
        LEFT JOIN dbo.PURCHASING_DR_TRACKING tr
            ON tr.DRID = dr.DRID
        LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS dd
            ON dd.DRID = dr.DRID
        WHERE rr.RepFID IS NOT NULL
          AND pr.RepFID = rr.RepFID
        ORDER BY po.POID DESC, dr.DRID DESC
    ) po
    WHERE l.InventoryLogID = @InventoryLogID;
END;
GO

CREATE   PROCEDURE dbo.usp_Receiving_ReceiveCheckedDRWithSignature
    @ActorUserID INT,
    @DRID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RepFID INT,
        @ItemID INT,
        @InventoryLogID BIGINT,
        @CheckerUserID INT,
        @CheckerName NVARCHAR(200),
        @CheckerRole NVARCHAR(100),
        @CheckerSig NVARCHAR(MAX),
        @CheckedAt DATETIME2(0),
        @RRHash CHAR(64);

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before receiving the checked delivery.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50732,
            'A signature is required to receive a checked delivery.',
            1;

    SELECT
        @RepFID = pr.RepFID,
        @ItemID = dd.ItemID
    FROM dbo.DELIVERY_RECEIPTS dr
    INNER JOIN dbo.PURCHASE_ORDERS po
        ON po.POID = dr.POID
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = po.PRID
    LEFT JOIN dbo.DELIVERY_RECEIPT_DETAILS dd
        ON dd.DRID = dr.DRID
    WHERE dr.DRID = @DRID;

    IF @ItemID IS NULL
        THROW 50733, 'The checked delivery could not be found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Purchasing_ReceiveCheckedDR
            @ActorUserID = @ActorUserID,
            @DRID = @DRID;

        SELECT @InventoryLogID = MAX(l.InventoryLogID)
        FROM dbo.INVENTORY_LOGS l
        WHERE l.ItemID = @ItemID
          AND l.UserID = @ActorUserID
          AND l.TransactionType = 'Stock In'
          AND l.ReferenceType = 'REPLENISHMENT'
          AND l.ReferenceID = @RepFID;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'RECEIVING_REPORT',
            @DocumentID = @InventoryLogID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        /* Copy Purchasing checker's signature from DELIVERY_CHECK to RECEIVING_REPORT Checked. */
        SELECT TOP (1)
            @CheckerUserID = ds.SignerUserID,
            @CheckerName = ds.SignerName,
            @CheckerRole = ds.SignerRole,
            @CheckerSig = ds.SignatureImage,
            @CheckedAt = ds.SignedAt
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE ds.DocumentType = 'DELIVERY_CHECK'
          AND ds.DocumentID = @DRID
          AND ds.Stage = 'Checked'
          AND ds.IsActive = 1
        ORDER BY ds.SignatureID DESC;

        IF @CheckerUserID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'RECEIVING_REPORT'
                 AND DocumentID = @InventoryLogID
                 AND Stage = 'Checked'
                 AND IsActive = 1
           )
        BEGIN
            SET @RRHash = dbo.fn_DocumentSignatureHash('RECEIVING_REPORT', @InventoryLogID);

            INSERT INTO dbo.DOCUMENT_SIGNATURES
            (
                DocumentType, DocumentID, Stage, SignerUserID, SignerName,
                SignerRole, SignatureImage, DocumentHash, ConfirmationAccepted,
                SignedAt, IsActive
            )
            VALUES
            (
                'RECEIVING_REPORT', @InventoryLogID, 'Checked',
                @CheckerUserID, @CheckerName, @CheckerRole, @CheckerSig,
                @RRHash, 1, @CheckedAt, 1
            );
        END;

        /* Auto-stamp Stock Card Custodian with latest receiving sign-off. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.DOCUMENT_SIGNATURES
            WHERE DocumentType = 'STOCK_CARD'
              AND DocumentID = @ItemID
              AND Stage = 'Custodian'
              AND IsActive = 1
              AND DocumentHash = dbo.fn_DocumentSignatureHash('STOCK_CARD', @ItemID)
        )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'STOCK_CARD',
                @DocumentID = @ItemID,
                @Stage = 'Custodian',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        /* Auto-stamp RepF Inventory Staff stage if not yet signed. */
        IF @RepFID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'REPLENISHMENT_REQUEST'
                 AND DocumentID = @RepFID
                 AND Stage = 'Inventory'
                 AND IsActive = 1
           )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'REPLENISHMENT_REQUEST',
                @DocumentID = @RepFID,
                @Stage = 'Inventory',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   3. RECEIVING WRAPPERS — auto-stamp STOCK_CARD Custodian &
      REPLENISHMENT_REQUEST Inventory when receiving stock
 */

CREATE   PROCEDURE dbo.usp_Receiving_ReceiveWithSignature
    @ActorUserID INT,
    @ItemID INT,
    @QuantityReceived INT,
    @RepFID INT = NULL,
    @Remarks NVARCHAR(1000) = NULL,
    @SignatureImage NVARCHAR(MAX) = NULL,
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @InventoryLogID BIGINT;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before recording the receipt.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50731,
            'A signature is required to receive stock.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Inventory_ReceiveStock
            @ActorUserID = @ActorUserID,
            @ItemID = @ItemID,
            @QuantityReceived = @QuantityReceived,
            @RepFID = @RepFID,
            @Remarks = @Remarks;

        SELECT @InventoryLogID = MAX(l.InventoryLogID)
        FROM dbo.INVENTORY_LOGS l
        WHERE l.ItemID = @ItemID
          AND l.UserID = @ActorUserID
          AND l.TransactionType = 'Stock In';

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ActorUserID,
            @DocumentType = 'RECEIVING_REPORT',
            @DocumentID = @InventoryLogID,
            @Stage = 'Received',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        /* Auto-stamp Stock Card Custodian with latest receiving sign-off. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.DOCUMENT_SIGNATURES
            WHERE DocumentType = 'STOCK_CARD'
              AND DocumentID = @ItemID
              AND Stage = 'Custodian'
              AND IsActive = 1
              AND DocumentHash = dbo.fn_DocumentSignatureHash('STOCK_CARD', @ItemID)
        )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'STOCK_CARD',
                @DocumentID = @ItemID,
                @Stage = 'Custodian',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        /* Auto-stamp RepF Inventory Staff stage if not yet signed. */
        IF @RepFID IS NOT NULL
           AND NOT EXISTS
           (
               SELECT 1
               FROM dbo.DOCUMENT_SIGNATURES
               WHERE DocumentType = 'REPLENISHMENT_REQUEST'
                 AND DocumentID = @RepFID
                 AND Stage = 'Inventory'
                 AND IsActive = 1
           )
        BEGIN
            EXEC dbo.usp_DocumentSignature_Sign
                @ActorUserID = @ActorUserID,
                @DocumentType = 'REPLENISHMENT_REQUEST',
                @DocumentID = @RepFID,
                @Stage = 'Inventory',
                @SignatureImage = @SignatureImage,
                @Confirmed = @Confirmed,
                @ReturnResult = 0;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE dbo.usp_Report_Audit
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'reports.audit'
    )
        THROW 50808, 'You do not have permission to view audit and security reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; UserID=', ISNULL(CAST(@RequestorUserID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode = 'AUD_PRINT_SIGNATURE'
    BEGIN
        DECLARE @SigAudit TABLE
        (
            EventDate DATETIME2(0),
            Category VARCHAR(30),
            DocumentType NVARCHAR(80),
            DocumentRef VARCHAR(40),
            StageOrAction VARCHAR(40),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            HashPrefix VARCHAR(20),
            IntegrityStatus VARCHAR(30),
            Details NVARCHAR(500)
        );

        INSERT INTO @SigAudit
        SELECT
            ds.SignedAt,
            'Digital Signature',
            CASE ds.DocumentType
                WHEN 'PURCHASE_ORDER' THEN N'Purchase Order'
                WHEN 'RECEIVING_REPORT' THEN N'Receiving Report'
                WHEN 'STOCK_CARD' THEN N'Stock Card'
                WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                WHEN 'REQUISITION' THEN N'Requisition Form'
                WHEN 'REPLENISHMENT_REQUEST' THEN N'Replenishment Request'
                WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                WHEN 'DELIVERY_CHECK' THEN N'Delivery Check'
                WHEN 'RETURN_SLIP' THEN N'Return Slip'
                ELSE ds.DocumentType
            END,
            CONCAT('#', ds.DocumentID),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            LEFT(ds.DocumentHash, 12),
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Snapshot Changed'
            END,
            CASE
                WHEN ds.IsActive = 0 THEN ISNULL(ds.RevokeReason, N'Revoked')
                ELSE N'Confirmed digital signature'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.SignerUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ds.DocumentType = @Status)
        UNION ALL
        SELECT
            ral.CreatedAt,
            'Report / Print',
            ral.ReportCode,
            CONCAT('LOG-', ral.ReportAuditID),
            CASE ral.ActionType
                WHEN 'GENERATE' THEN 'Viewed'
                WHEN 'PRINT' THEN 'Printed'
                WHEN 'DOC_PRINT' THEN 'Printed Document'
                WHEN 'EXPORT_CSV' THEN 'Exported (CSV)'
                WHEN 'EXPORT_EXCEL' THEN 'Exported (Excel)'
                ELSE ral.ActionType
            END,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            ral.ActorRole,
            N'—',
            'Logged',
            ISNULL(ral.FilterSummary, N'')
        FROM dbo.REPORT_AUDIT_LOGS ral
        INNER JOIN dbo.USERS u ON u.UserID = ral.ActorUserID
        WHERE (@DateFrom IS NULL OR ral.CreatedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ral.CreatedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ral.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ral.ActionType = @Status);

        SELECT @RowCount = COUNT(*) FROM @SigAudit;

        SELECT
            @RowCount AS TotalEvents,
            ISNULL(SUM(CASE WHEN Category = 'Digital Signature' THEN 1 ELSE 0 END), 0) AS SignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedSignatures,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked' THEN 1 ELSE 0 END), 0) AS RevokedSignatures,
            ISNULL(SUM(CASE WHEN Category = 'Report / Print' THEN 1 ELSE 0 END), 0) AS ReportPrintEvents
        FROM @SigAudit;

        SELECT * FROM @SigAudit ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_CORRECTION_HISTORY'
    BEGIN
        DECLARE @CorHist TABLE
        (
            EventDate DATETIME2(0),
            RecordType VARCHAR(40),
            DocumentRef NVARCHAR(120),
            ActorName NVARCHAR(200),
            Summary NVARCHAR(1000),
            Status VARCHAR(30)
        );

        INSERT INTO @CorHist
        SELECT
            ISNULL(d.CorrectedAt, d.GeneratedDate),
            'AR Discrepancy / Correction',
            d.ARCode,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName)))
                 ELSE LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))) END,
            CONCAT(
                'Discrepancy: ', ISNULL(d.DiscrepancyNotes, N'—'),
                CASE WHEN d.CorrectionNotes IS NOT NULL THEN CONCAT(' | Correction: ', d.CorrectionNotes) ELSE '' END
            ),
            CASE WHEN d.DiscrepancyResolvedAt IS NOT NULL THEN 'Resolved' WHEN d.CorrectedAt IS NOT NULL THEN 'Corrected' ELSE 'Open' END
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        WHERE (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          AND (@DateFrom IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR d.CorrectedByUserID = @RequestorUserID OR d.RequestorUserID = @RequestorUserID)
        UNION ALL
        SELECT
            ISNULL(ds.RevokedAt, ds.SignedAt),
            'Signature Revoked / Superseded',
            CONCAT(
                CASE ds.DocumentType
                    WHEN 'PURCHASE_ORDER' THEN N'Purchase Order'
                    WHEN 'RECEIVING_REPORT' THEN N'Receiving Report'
                    WHEN 'STOCK_CARD' THEN N'Stock Card'
                    WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                    WHEN 'REQUISITION' THEN N'Requisition Form'
                    WHEN 'REPLENISHMENT_REQUEST' THEN N'Replenishment Request'
                    WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                    WHEN 'DELIVERY_CHECK' THEN N'Delivery Check'
                    WHEN 'RETURN_SLIP' THEN N'Return Slip'
                    ELSE ds.DocumentType
                END,
                N' #', ds.DocumentID, N' (', ds.Stage, N')'
            ),
            LTRIM(RTRIM(CONCAT(rv.FirstName, ' ', rv.LastName))),
            ISNULL(ds.RevokeReason, N'Revoked'),
            'Revoked'
        FROM dbo.DOCUMENT_SIGNATURES ds
        LEFT JOIN dbo.USERS rv ON rv.UserID = ds.RevokedByUserID
        WHERE ds.IsActive = 0
          AND (@DateFrom IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.RevokedByUserID = @RequestorUserID);

        SELECT @RowCount = COUNT(*) FROM @CorHist;

        SELECT
            @RowCount AS TotalCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'AR Discrepancy / Correction' THEN 1 ELSE 0 END), 0) AS DeliveryCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'Signature Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS SignatureRevocations
        FROM @CorHist;

        SELECT * FROM @CorHist ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_USER_ACTIVITY'
    BEGIN
        DECLARE @Activity TABLE
        (
            AuditID BIGINT,
            ActionDate DATETIME2(0),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            ActionType VARCHAR(60),
            TargetUser NVARCHAR(200),
            Description NVARCHAR(1000)
        );

        INSERT INTO @Activity
        SELECT TOP (1000)
            a.AuditID,
            a.ActionDate,
            LTRIM(RTRIM(CONCAT(actor.FirstName, ' ', actor.LastName))),
            r.RoleName,
            a.ActionType,
            CASE WHEN target.UserID IS NOT NULL
                 THEN LTRIM(RTRIM(CONCAT(target.FirstName, ' ', target.LastName)))
                 ELSE N'—' END,
            a.Description
        FROM dbo.USER_AUDIT_LOGS a
        INNER JOIN dbo.USERS actor ON actor.UserID = a.ActorUserID
        INNER JOIN dbo.ROLES r ON r.RoleID = actor.RoleID
        LEFT JOIN dbo.USERS target ON target.UserID = a.TargetUserID
        WHERE (@DateFrom IS NULL OR a.ActionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR a.ActionDate <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR a.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR a.ActionType = @Status)
        ORDER BY a.ActionDate DESC, a.AuditID DESC;

        SELECT @RowCount = COUNT(*) FROM @Activity;

        SELECT
            @RowCount AS TotalActivities,
            COUNT(DISTINCT ActorName) AS DistinctActors,
            COUNT(DISTINCT ActionType) AS DistinctActionTypes
        FROM @Activity;

        SELECT * FROM @Activity ORDER BY ActionDate DESC, AuditID DESC;
    END
    ELSE
        THROW 50809, 'Unknown audit report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   3. DELIVERY SIGNATURE HISTORY — Human-Readable Source Labels
*/

CREATE   PROCEDURE dbo.usp_Report_Delivery
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL,
    @DepartmentRole NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
        THROW 50806, 'You do not have permission to view delivery reports.', 1;

    DECLARE @ScopedRequestorID INT =
        CASE WHEN @RoleName = N'Staff' THEN @ActorUserID ELSE @RequestorUserID END;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; Requestor=', ISNULL(CAST(@ScopedRequestorID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('DEL_AR_REGISTER', 'DEL_ISSUED_COMPLETED', 'DEL_DISCREPANCY_CORRECTION')
    BEGIN
        DECLARE @ARs TABLE
        (
            DeliveryID INT,
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            RequestorName NVARCHAR(200),
            RequestorRole NVARCHAR(100),
            Status VARCHAR(30),
            TotalItems INT,
            TotalQuantity INT,
            GeneratedDate DATETIME2(0),
            IssuedDate DATETIME2(0),
            SignedDate DATETIME2(0),
            IssuedByName NVARCHAR(200),
            SignedByName NVARCHAR(200),
            DiscrepancyNotes NVARCHAR(1000),
            CorrectionNotes NVARCHAR(500),
            CorrectedByName NVARCHAR(200),
            CorrectedAt DATETIME2(0)
        );

        INSERT INTO @ARs
        SELECT
            d.DeliveryID,
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            d.Status,
            COUNT(di.DeliveryItemID),
            ISNULL(SUM(di.Quantity), 0),
            d.GeneratedDate,
            d.IssuedDate,
            d.SignedDate,
            CASE WHEN iss.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(iss.FirstName, ' ', iss.LastName))) ELSE N'—' END,
            CASE WHEN sig.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(sig.FirstName, ' ', sig.LastName))) ELSE N'—' END,
            d.DiscrepancyNotes,
            d.CorrectionNotes,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName))) ELSE N'—' END,
            d.CorrectedAt
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.USERS iss ON iss.UserID = d.IssuedByUserID
        LEFT JOIN dbo.USERS sig ON sig.UserID = d.SignedByUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        LEFT JOIN dbo.DELIVERY_ITEMS di ON di.DeliveryID = d.DeliveryID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = di.ItemID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR d.GeneratedDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR d.GeneratedDate <= @DateToEnd)
          AND (NULLIF(@Status, '') IS NULL OR d.Status = @Status)
          AND (@ItemID IS NULL OR di.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (
              @ReportCode <> 'DEL_ISSUED_COMPLETED'
              OR d.Status IN ('Issued', 'Completed')
          )
          AND (
              @ReportCode <> 'DEL_DISCREPANCY_CORRECTION'
              OR (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          )
        GROUP BY
            d.DeliveryID, d.ARCode, d.RequisitionID,
            req.FirstName, req.LastName, reqRole.RoleName,
            d.Status, d.GeneratedDate, d.IssuedDate, d.SignedDate,
            iss.UserID, iss.FirstName, iss.LastName,
            sig.UserID, sig.FirstName, sig.LastName,
            d.DiscrepancyNotes, d.CorrectionNotes,
            cor.UserID, cor.FirstName, cor.LastName, d.CorrectedAt;

        SELECT @RowCount = COUNT(*) FROM @ARs;

        SELECT
            @RowCount AS TotalARs,
            ISNULL(SUM(TotalQuantity), 0) AS TotalDeliveredUnits,
            ISNULL(SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END), 0) AS CompletedCount,
            ISNULL(SUM(CASE WHEN Status = 'Issued' THEN 1 ELSE 0 END), 0) AS IssuedCount,
            ISNULL(SUM(CASE WHEN NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL THEN 1 ELSE 0 END), 0) AS WithDiscrepancyCount
        FROM @ARs;

        SELECT * FROM @ARs ORDER BY GeneratedDate DESC, DeliveryID DESC;
    END
    ELSE IF @ReportCode = 'DEL_SIGNATURE_HISTORY'
    BEGIN
        DECLARE @SigHist TABLE
        (
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            Stage VARCHAR(40),
            SignerName NVARCHAR(200),
            SignerRole NVARCHAR(100),
            SignedAt DATETIME2(0),
            Source NVARCHAR(60),
            IntegrityStatus VARCHAR(30)
        );

        INSERT INTO @SigHist
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            h.Stage,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            r.RoleName,
            h.SignedAt,
            N'Delivery History',
            'Archived'
        FROM dbo.DELIVERY_SIGNATURE_HISTORY h
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = h.DeliveryID
        INNER JOIN dbo.USERS u ON u.UserID = h.UserID
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR h.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR h.SignedAt <= @DateToEnd)
        UNION ALL
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            ds.SignedAt,
            CASE ds.DocumentType
                WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                ELSE ds.DocumentType
            END,
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked / Superseded'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Hash Mismatch'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = ds.DocumentID
        WHERE ds.DocumentType IN ('ACKNOWLEDGEMENT_RECEIPT', 'CORRECTION_REPORT')
          AND (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd);

        SELECT @RowCount = COUNT(*) FROM @SigHist;

        SELECT
            @RowCount AS TotalSignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedCount,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS RevokedCount
        FROM @SigHist;

        SELECT * FROM @SigHist ORDER BY SignedAt DESC;
    END
    ELSE
        THROW 50809, 'Unknown delivery report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   4. FILTER OPTIONS & ACTOR CONTEXT (1 DB CALL ON PAGE LOAD)
 */

CREATE   PROCEDURE dbo.usp_Report_GetFilterOptions
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RoleName NVARCHAR(100),
        @CanView BIT = 0,
        @CanExport BIT = 0,
        @CanAudit BIT = 0;

    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF @RoleName IS NULL
        THROW 50800, 'Your session is no longer active.', 1;

    SELECT
        @CanView = MAX(CASE WHEN p.PermissionCode = 'reports.view' THEN 1 ELSE 0 END),
        @CanExport = MAX(CASE WHEN p.PermissionCode = 'reports.export' THEN 1 ELSE 0 END),
        @CanAudit = MAX(CASE WHEN p.PermissionCode = 'reports.audit' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID;

    IF ISNULL(@CanView, 0) = 0
        THROW 50801, 'You do not have permission to view reports.', 1;

    /* RS1: context & branding */
    SELECT
        @RoleName AS ActorRole,
        CAST(ISNULL(@CanExport, 0) AS BIT) AS CanExport,
        CAST(ISNULL(@CanAudit, 0) AS BIT) AS CanAudit,
        (SELECT SettingValue FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'SalonName') AS SalonName,
        (SELECT SettingValue FROM dbo.SYSTEM_SETTINGS WHERE SettingKey = 'SalonTagline') AS SalonTagline;

    /* RS2: categories */
    SELECT CategoryID, CategoryName
    FROM dbo.CATEGORIES
    WHERE IsActive = 1
    ORDER BY CategoryName;

    /* RS3: items */
    SELECT ItemID, ItemCode, ItemName, CategoryID
    FROM dbo.ITEMS
    ORDER BY ItemName;

    /* RS4: suppliers */
    SELECT SupplierID, SupplierCode, SupplierName
    FROM dbo.SUPPLIERS
    ORDER BY SupplierName;

    /* RS5: users/requestors (row-scoped for Staff) */
    SELECT
        u.UserID,
        LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))) AS FullName,
        r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE (@RoleName <> N'Staff' OR u.UserID = @ActorUserID)
    ORDER BY u.FirstName, u.LastName;

    /* RS6: roles (department/role filter) */
    SELECT RoleID, RoleName
    FROM dbo.ROLES
    WHERE IsActive = 1
    ORDER BY RoleName;
END;
GO

/* 
   5. INVENTORY REPORTS
 */

CREATE   PROCEDURE dbo.usp_Report_Inventory
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @AsOfDate DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    DECLARE @HasAccess BIT = 0;

    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND p.PermissionCode = 'reports.view'
    )
    AND (
        @RoleName IN (N'Admin', N'Manager')
        OR EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID
              AND p.PermissionCode IN ('inventory.view', 'receiving.view', 'purchasing.view')
        )
    )
        SET @HasAccess = 1;

    IF @HasAccess = 0
        THROW 50802, 'You do not have permission to view inventory reports.', 1;

    DECLARE @EffectiveTo DATETIME2(0) =
        CASE
            WHEN @AsOfDate IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@AsOfDate AS DATETIME2(0)))
            WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0)))
            ELSE NULL
        END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; AsOf=', ISNULL(CONVERT(VARCHAR(10), @AsOfDate, 23), 'Current'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; CategoryID=', ISNULL(CAST(@CategoryID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('INV_STOCK_CARD', 'INV_MOVEMENT_LEDGER', 'INV_ADJUSTMENTS')
    BEGIN
        DECLARE @Movements TABLE
        (
            InventoryLogID BIGINT,
            TransactionDate DATETIME2(0),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            UnitOfMeasure NVARCHAR(40),
            TransactionType VARCHAR(40),
            ReferenceDisplay VARCHAR(40),
            SourceDisplay VARCHAR(30),
            PreviousQuantity INT,
            QuantityChange INT,
            NewQuantity INT,
            ActorName NVARCHAR(200),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Movements
        SELECT
            l.InventoryLogID,
            l.TransactionDate,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.UnitOfMeasure,
            l.TransactionType,
            CASE l.ReferenceType
                WHEN 'RECEIVING' THEN 'RR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'REPLENISHMENT' THEN 'RepF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'DELIVERY' THEN 'AR-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'REQUISITION' THEN 'RF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'ADJUSTMENT' THEN 'ADJ-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                WHEN 'PURCHASE' THEN 'PO-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                ELSE N'—'
            END,
            CASE l.ReferenceType
                WHEN 'RECEIVING' THEN 'Receiving'
                WHEN 'REPLENISHMENT' THEN 'Replenishment'
                WHEN 'DELIVERY' THEN 'Issuance'
                WHEN 'REQUISITION' THEN 'Requisition'
                WHEN 'ADJUSTMENT' THEN 'Adjustment'
                WHEN 'PURCHASE' THEN 'Purchase'
                ELSE 'System'
            END,
            l.PreviousQuantity,
            l.QuantityChange,
            l.NewQuantity,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            l.Remarks
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.ITEMS i ON i.ItemID = l.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.USERS u ON u.UserID = l.UserID
        WHERE (@ItemID IS NULL OR l.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (@DateFrom IS NULL OR l.TransactionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@EffectiveTo IS NULL OR l.TransactionDate <= @EffectiveTo)
          AND (
              @ReportCode <> 'INV_ADJUSTMENTS'
              OR l.TransactionType = 'Adjustment'
              OR l.ReferenceType = 'ADJUSTMENT'
          )
          AND (NULLIF(@Status, '') IS NULL OR l.TransactionType = @Status);

        SELECT @RowCount = COUNT(*) FROM @Movements;

        /* RS1: Summary */
        SELECT
            @RowCount AS TotalMovements,
            ISNULL(SUM(CASE WHEN QuantityChange > 0 THEN QuantityChange ELSE 0 END), 0) AS TotalStockIn,
            ISNULL(SUM(CASE WHEN QuantityChange < 0 THEN -QuantityChange ELSE 0 END), 0) AS TotalStockOut,
            ISNULL(SUM(QuantityChange), 0) AS NetChange
        FROM @Movements;

        /* RS2: Details */
        SELECT *
        FROM @Movements
        ORDER BY
            CASE WHEN @ReportCode = 'INV_STOCK_CARD' THEN TransactionDate END ASC,
            CASE WHEN @ReportCode = 'INV_STOCK_CARD' THEN InventoryLogID END ASC,
            TransactionDate DESC,
            InventoryLogID DESC;
    END
    ELSE IF @ReportCode IN ('INV_STOCK_POSITION', 'INV_LOW_STOCK')
    BEGIN
        /* Historical As-Of reconstruction: roll back logs strictly after @AsOfDate end-of-day. */
        DECLARE @AsOfEnd DATETIME2(0) =
            CASE WHEN @AsOfDate IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@AsOfDate AS DATETIME2(0))) ELSE NULL END;

        DECLARE @Positions TABLE
        (
            ItemID INT,
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            UnitOfMeasure NVARCHAR(40),
            UnitPrice DECIMAL(18,2),
            ReorderPoint INT,
            QuantityOnHand INT,
            QuantityReserved INT,
            QuantityAvailable INT,
            InventoryValue DECIMAL(18,2),
            StockStatus VARCHAR(30),
            SuggestedReorder INT,
            LastUpdated DATETIME2(0)
        );

        INSERT INTO @Positions
        SELECT
            i.ItemID,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.UnitOfMeasure,
            i.UnitPrice,
            i.ReorderPoint,
            pos.OnHandAsOf,
            pos.ReservedQty,
            pos.AvailableAsOf,
            CAST(pos.OnHandAsOf AS DECIMAL(18,2)) * i.UnitPrice,
            CASE
                WHEN i.IsActive = 0 THEN 'Inactive'
                WHEN pos.OnHandAsOf <= 0 THEN 'No stock'
                WHEN pos.AvailableAsOf <= 0 THEN 'Fully reserved'
                WHEN pos.AvailableAsOf <= i.ReorderPoint THEN 'Low stock'
                ELSE 'OK'
            END,
            CASE
                WHEN pos.AvailableAsOf <= i.ReorderPoint
                    THEN (i.ReorderPoint - pos.AvailableAsOf) + CASE WHEN i.ReorderPoint > 0 THEN i.ReorderPoint ELSE 5 END
                ELSE 0
            END,
            inv.LastUpdated
        FROM dbo.ITEMS i
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.INVENTORY inv ON inv.ItemID = i.ItemID
        OUTER APPLY
        (
            SELECT ISNULL(SUM(l.QuantityChange), 0) AS DeltaAfterAsOf
            FROM dbo.INVENTORY_LOGS l
            WHERE @AsOfEnd IS NOT NULL
              AND l.ItemID = i.ItemID
              AND l.TransactionDate > @AsOfEnd
        ) afterLogs
        CROSS APPLY
        (
            SELECT
                CASE
                    WHEN ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf < 0 THEN 0
                    ELSE ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf
                END AS OnHandAsOf,
                ISNULL(inv.QuantityReserved, 0) AS ReservedQty,
                (
                    CASE
                        WHEN ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf < 0 THEN 0
                        ELSE ISNULL(inv.QuantityOnHand, 0) - afterLogs.DeltaAfterAsOf
                    END - ISNULL(inv.QuantityReserved, 0)
                ) AS AvailableAsOf
        ) pos
        WHERE (@ItemID IS NULL OR i.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (
              @ReportCode <> 'INV_LOW_STOCK'
              OR (i.IsActive = 1 AND (pos.OnHandAsOf <= 0 OR pos.AvailableAsOf <= i.ReorderPoint))
          )
          AND (
              NULLIF(@Status, '') IS NULL
              OR (
                  CASE
                      WHEN i.IsActive = 0 THEN 'Inactive'
                      WHEN pos.OnHandAsOf <= 0 THEN 'No stock'
                      WHEN pos.AvailableAsOf <= 0 THEN 'Fully reserved'
                      WHEN pos.AvailableAsOf <= i.ReorderPoint THEN 'Low stock'
                      ELSE 'OK'
                  END
              ) = @Status
          );

        SELECT @RowCount = COUNT(*) FROM @Positions;

        /* RS1: Summary */
        SELECT
            @RowCount AS TotalItems,
            ISNULL(SUM(QuantityOnHand), 0) AS TotalOnHand,
            ISNULL(SUM(QuantityReserved), 0) AS TotalReserved,
            ISNULL(SUM(QuantityAvailable), 0) AS TotalAvailable,
            ISNULL(SUM(InventoryValue), 0) AS TotalValuation,
            ISNULL(SUM(CASE WHEN StockStatus IN ('Low stock', 'No stock', 'Fully reserved') THEN 1 ELSE 0 END), 0) AS LowOrOutCount
        FROM @Positions;

        /* RS2: Details */
        SELECT
            ItemCode,
            ItemName,
            CategoryName,
            UnitOfMeasure,
            QuantityOnHand,
            QuantityReserved,
            QuantityAvailable,
            ReorderPoint,
            UnitPrice,
            InventoryValue,
            StockStatus,
            SuggestedReorder,
            LastUpdated
        FROM @Positions
        ORDER BY
            CASE WHEN @ReportCode = 'INV_LOW_STOCK' THEN QuantityAvailable END ASC,
            ItemName ASC;
    END
    ELSE
        THROW 50809, 'Unknown inventory report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

CREATE   PROCEDURE dbo.usp_Report_LogAction
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @ActionType VARCHAR(30),
    @FilterSummary NVARCHAR(1000) = NULL,
    @RowCount INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActorRole NVARCHAR(100);

    SELECT @ActorRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF @ActorRole IS NULL
        RETURN;

    INSERT INTO dbo.REPORT_AUDIT_LOGS
    (
        ActorUserID, ActorRole, ReportCode, ActionType,
        FilterSummary, [RowCount], CreatedAt
    )
    VALUES
    (
        @ActorUserID, @ActorRole, LEFT(@ReportCode, 60),
        LEFT(@ActionType, 30), LEFT(@FilterSummary, 1000),
        @RowCount, SYSDATETIME()
    );

    IF @ActionType IN ('PRINT', 'EXPORT_CSV', 'EXPORT_EXCEL', 'DOC_PRINT')
    BEGIN
        DECLARE @CleanFilter NVARCHAR(250) = NULLIF(LTRIM(RTRIM(@FilterSummary)), N'');
        DECLARE @RowText NVARCHAR(40) =
            CASE
                WHEN @RowCount IS NULL THEN N''
                WHEN @RowCount = 1 THEN N'1 row'
                ELSE CONCAT(@RowCount, N' rows')
            END;

        DECLARE @Description NVARCHAR(500);

        IF @ActionType = 'DOC_PRINT'
        BEGIN
            SET @Description = CONCAT(
                N'Printed ',
                @ReportCode,
                N'.'
            );
        END
        ELSE
        BEGIN
            DECLARE @Verb NVARCHAR(40) =
                CASE @ActionType
                    WHEN 'PRINT' THEN N'Printed'
                    WHEN 'EXPORT_CSV' THEN N'Exported to CSV:'
                    WHEN 'EXPORT_EXCEL' THEN N'Exported to Excel:'
                    ELSE @ActionType
                END;

            SET @Description = CONCAT(
                @Verb, N' ', @ReportCode,
                CASE
                    WHEN @RowText <> N'' AND @CleanFilter IS NOT NULL AND @CleanFilter <> N'All records'
                        THEN CONCAT(N' (', @RowText, N' · ', @CleanFilter, N')')
                    WHEN @RowText <> N''
                        THEN CONCAT(N' (', @RowText, N')')
                    WHEN @CleanFilter IS NOT NULL AND @CleanFilter <> N'All records'
                        THEN CONCAT(N' (', @CleanFilter, N')')
                    ELSE N''
                END,
                N'.'
            );
        END;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID,
            @ActorUserID,
            'REPORT_' + LEFT(@ActionType, 20),
            LEFT(@Description, 500)
        );
    END;
END;
GO

/* 
   6. PURCHASING REPORTS
  */

CREATE   PROCEDURE dbo.usp_Report_Purchasing
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @SupplierID INT = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('purchasing.view', 'purchasing.manage')
        )
    )
        THROW 50803, 'You do not have permission to view purchasing reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; SupplierID=', ISNULL(CAST(@SupplierID AS VARCHAR(20)), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('PUR_PO_REGISTER', 'PUR_PO_OUTSTANDING')
    BEGIN
        DECLARE @POs TABLE
        (
            POID INT,
            POCode VARCHAR(20),
            PRCode VARCHAR(20),
            RepFCode VARCHAR(20),
            DateIssued DATETIME2(0),
            ExpectedDate DATE,
            DispatchedAt DATETIME2(0),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            QuantityOrdered INT,
            AcceptedQuantity INT,
            StockedQuantity INT,
            OutstandingQuantity INT,
            UnitPrice DECIMAL(18,2),
            TotalAmount DECIMAL(18,2),
            Status VARCHAR(30),
            ApprovedByName NVARCHAR(200),
            IsOverdue VARCHAR(10)
        );

        INSERT INTO @POs
        SELECT
            po.POID,
            'PO-' + RIGHT('0000' + CAST(po.POID AS VARCHAR(10)), 4),
            'PR-' + RIGHT('0000' + CAST(po.PRID AS VARCHAR(10)), 4),
            'RepF-' + RIGHT('0000' + CAST(rr.RepFID AS VARCHAR(10)), 4),
            po.DateIssued,
            t.ExpectedDate,
            t.DispatchedAt,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            po.QuantityOrdered,
            ISNULL(a.AcceptedQty, 0),
            ISNULL(m.StockedQty, 0),
            po.QuantityOrdered - ISNULL(a.AcceptedQty, 0),
            po.UnitPrice,
            po.TotalAmount,
            po.Status,
            LTRIM(RTRIM(CONCAT(ap.FirstName, ' ', ap.LastName))),
            CASE
                WHEN t.ExpectedDate IS NOT NULL
                     AND t.ExpectedDate < CAST(SYSDATETIME() AS DATE)
                     AND (po.QuantityOrdered - ISNULL(a.AcceptedQty, 0)) > 0
                     AND po.Status NOT IN ('Delivered', 'Rejected', 'Cancelled')
                    THEN 'Overdue'
                ELSE 'On Track'
            END
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        LEFT JOIN dbo.PURCHASING_PO_TRACKING t ON t.POID = po.POID
        LEFT JOIN dbo.USERS ap ON ap.UserID = po.ApprovedByUserID
        OUTER APPLY
        (
            SELECT SUM(drd.QuantityAccepted) AS AcceptedQty
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS drd ON drd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) a
        OUTER APPLY
        (
            SELECT SUM(rmd.QuantityReceived) AS StockedQty
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
            INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
            WHERE dr.POID = po.POID AND rm.InventoryUpdated = 1
        ) m
        WHERE (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status)
          AND (
              @ReportCode <> 'PUR_PO_OUTSTANDING'
              OR (po.Status NOT IN ('Delivered', 'Rejected', 'Cancelled')
                  AND (po.QuantityOrdered - ISNULL(a.AcceptedQty, 0)) > 0)
          );

        SELECT @RowCount = COUNT(*) FROM @POs;

        SELECT
            @RowCount AS TotalPOs,
            ISNULL(SUM(QuantityOrdered), 0) AS TotalOrdered,
            ISNULL(SUM(AcceptedQuantity), 0) AS TotalAccepted,
            ISNULL(SUM(OutstandingQuantity), 0) AS TotalOutstanding,
            ISNULL(SUM(TotalAmount), 0) AS TotalSpend
        FROM @POs;

        SELECT * FROM @POs ORDER BY DateIssued DESC, POID DESC;
    END
    ELSE IF @ReportCode = 'PUR_SUPPLIER_PERF'
    BEGIN
        DECLARE @Perf TABLE
        (
            SupplierCode VARCHAR(30),
            SupplierName NVARCHAR(200),
            TotalPOs INT,
            TotalSpend DECIMAL(18,2),
            TotalOrdered INT,
            TotalDelivered INT,
            TotalAccepted INT,
            TotalRejected INT,
            AcceptanceRatePct DECIMAL(6,2),
            ReturnSlipCount INT
        );

        INSERT INTO @Perf
        SELECT
            s.SupplierCode,
            s.SupplierName,
            COUNT(DISTINCT po.POID),
            ISNULL(SUM(po.TotalAmount), 0),
            ISNULL(SUM(po.QuantityOrdered), 0),
            ISNULL(SUM(drStats.Delivered), 0),
            ISNULL(SUM(drStats.Accepted), 0),
            ISNULL(SUM(drStats.Rejected), 0),
            CASE
                WHEN ISNULL(SUM(drStats.Delivered), 0) > 0
                    THEN CAST(ISNULL(SUM(drStats.Accepted), 0) * 100.0 / SUM(drStats.Delivered) AS DECIMAL(6,2))
                ELSE 0
            END,
            ISNULL(SUM(drStats.RejectedDRs), 0)
        FROM dbo.SUPPLIERS s
        LEFT JOIN dbo.PURCHASE_ORDERS po
            ON po.SupplierID = s.SupplierID
           AND (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
           AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
           AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status)
        OUTER APPLY
        (
            SELECT
                SUM(dd.QuantityDelivered) AS Delivered,
                SUM(dd.QuantityAccepted) AS Accepted,
                SUM(dd.QuantityRejected) AS Rejected,
                COUNT(DISTINCT CASE WHEN dd.QuantityRejected > 0 THEN dr.DRID END) AS RejectedDRs
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) drStats
        WHERE (@SupplierID IS NULL OR s.SupplierID = @SupplierID)
        GROUP BY s.SupplierCode, s.SupplierName
        HAVING COUNT(DISTINCT po.POID) > 0 OR @SupplierID IS NOT NULL;

        SELECT @RowCount = COUNT(*) FROM @Perf;

        SELECT
            @RowCount AS ActiveSuppliers,
            ISNULL(SUM(TotalPOs), 0) AS TotalPOs,
            ISNULL(SUM(TotalSpend), 0) AS TotalSpend,
            ISNULL(SUM(TotalAccepted), 0) AS TotalAccepted,
            ISNULL(SUM(TotalRejected), 0) AS TotalRejected
        FROM @Perf;

        SELECT * FROM @Perf ORDER BY TotalSpend DESC, SupplierName ASC;
    END
    ELSE IF @ReportCode = 'PUR_RETURN_SLIPS'
    BEGIN
        DECLARE @Returns TABLE
        (
            SlipNo VARCHAR(20),
            DeliveryDate DATETIME2(0),
            POCode VARCHAR(20),
            SupplierDRNumber NVARCHAR(100),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            Status VARCHAR(30),
            ReplacementRequestedAt DATETIME2(0),
            RecordedByName NVARCHAR(200),
            Notes NVARCHAR(1000)
        );

        INSERT INTO @Returns
        SELECT
            'RS-' + RIGHT('0000' + CAST(dr.DRID AS VARCHAR(10)), 4),
            dr.DeliveryDate,
            'PO-' + RIGHT('0000' + CAST(dr.POID AS VARCHAR(10)), 4),
            tr.SupplierDRNumber,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            dd.QuantityDelivered,
            dd.QuantityAccepted,
            dd.QuantityRejected,
            dr.Status,
            tr.ReplacementRequestedAt,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            ISNULL(dd.Remarks, dr.Notes)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
        LEFT JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
        LEFT JOIN dbo.USERS u ON u.UserID = tr.RecordedByUserID
        WHERE dd.QuantityRejected > 0
          AND (@DateFrom IS NULL OR dr.DeliveryDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR dr.DeliveryDate <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR dd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR dr.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Returns;

        SELECT
            @RowCount AS TotalReturnSlips,
            ISNULL(SUM(QuantityDelivered), 0) AS TotalDelivered,
            ISNULL(SUM(QuantityRejected), 0) AS TotalRejected,
            ISNULL(SUM(CASE WHEN ReplacementRequestedAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS ReplacementRequestedCount
        FROM @Returns;

        SELECT * FROM @Returns ORDER BY DeliveryDate DESC;
    END
    ELSE IF @ReportCode = 'PUR_QUOTATION_HISTORY'
    BEGIN
        DECLARE @Quotes TABLE
        (
            QuotationID INT,
            DateQuoted DATETIME2(0),
            PRCode VARCHAR(20),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            SupplierName NVARCHAR(200),
            QuotedPrice DECIMAL(18,2),
            Recommended VARCHAR(10),
            PRStatus VARCHAR(30)
        );

        INSERT INTO @Quotes
        SELECT
            q.QuotationID,
            q.DateQuoted,
            'PR-' + RIGHT('0000' + CAST(q.PRID AS VARCHAR(10)), 4),
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            s.SupplierName,
            q.QuotedPrice,
            CASE WHEN q.IsRecommended = 1 THEN 'Yes' ELSE 'No' END,
            pr.Status
        FROM dbo.SUPPLIER_QUOTATIONS q
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = q.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = q.SupplierID
        WHERE (@DateFrom IS NULL OR q.DateQuoted >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR q.DateQuoted <= @DateToEnd)
          AND (@SupplierID IS NULL OR q.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR pr.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Quotes;

        SELECT
            @RowCount AS TotalQuotations,
            ISNULL(SUM(CASE WHEN Recommended = 'Yes' THEN 1 ELSE 0 END), 0) AS RecommendedCount,
            ISNULL(AVG(QuotedPrice), 0) AS AveragePrice,
            ISNULL(MIN(QuotedPrice), 0) AS LowestPrice,
            ISNULL(MAX(QuotedPrice), 0) AS HighestPrice
        FROM @Quotes;

        SELECT * FROM @Quotes ORDER BY DateQuoted DESC, QuotationID DESC;
    END
    ELSE
        THROW 50809, 'Unknown purchasing report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   7. RECEIVING REPORTS
 */

CREATE   PROCEDURE dbo.usp_Report_Receiving
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @SupplierID INT = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('receiving.view', 'receiving.manage', 'inventory.view')
        )
    )
        THROW 50804, 'You do not have permission to view receiving reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; SupplierID=', ISNULL(CAST(@SupplierID AS VARCHAR(20)), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('REC_RR_REGISTER', 'REC_MANUAL_RECEIPTS')
    BEGIN
        DECLARE @Receipts TABLE
        (
            InventoryLogID BIGINT,
            ReportNo VARCHAR(30),
            TransactionDate DATETIME2(0),
            SourceDisplay VARCHAR(30),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            CategoryName NVARCHAR(100),
            QuantityReceived INT,
            PreviousQuantity INT,
            NewQuantity INT,
            SupplierName NVARCHAR(200),
            POCode VARCHAR(20),
            ReceivedByName NVARCHAR(200),
            SignedStatus VARCHAR(20),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Receipts
        SELECT
            l.InventoryLogID,
            CASE
                WHEN l.ReferenceType = 'REPLENISHMENT' AND l.ReferenceID IS NOT NULL
                    THEN 'RepF-' + RIGHT('0000' + CAST(l.ReferenceID AS VARCHAR(10)), 4)
                ELSE 'RR-' + RIGHT('0000' + CAST(l.InventoryLogID AS VARCHAR(10)), 4)
            END,
            l.TransactionDate,
            CASE WHEN l.ReferenceType = 'REPLENISHMENT' THEN 'Replenishment' ELSE 'Manual receipt' END,
            i.ItemCode,
            i.ItemName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            l.QuantityChange,
            l.PreviousQuantity,
            l.NewQuantity,
            ISNULL(poCtx.SupplierName, N'—'),
            CASE WHEN poCtx.POID IS NOT NULL THEN 'PO-' + RIGHT('0000' + CAST(poCtx.POID AS VARCHAR(10)), 4) ELSE N'—' END,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            CASE WHEN sig.SignatureID IS NOT NULL THEN 'Digitally signed' ELSE 'Unsigned' END,
            l.Remarks
        FROM dbo.INVENTORY_LOGS l
        INNER JOIN dbo.ITEMS i ON i.ItemID = l.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        LEFT JOIN dbo.USERS u ON u.UserID = l.UserID
        OUTER APPLY
        (
            SELECT TOP (1) po.POID, po.SupplierID, s.SupplierName
            FROM dbo.PURCHASE_REQUESTS pr
            INNER JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
            INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
            WHERE l.ReferenceType = 'REPLENISHMENT' AND pr.RepFID = l.ReferenceID
            ORDER BY po.POID DESC
        ) poCtx
        OUTER APPLY
        (
            SELECT TOP (1) ds.SignatureID
            FROM dbo.DOCUMENT_SIGNATURES ds
            WHERE ds.DocumentType = 'RECEIVING_REPORT'
              AND ds.DocumentID = l.InventoryLogID
              AND ds.Stage = 'Received'
              AND ds.IsActive = 1
        ) sig
        WHERE l.TransactionType = 'Stock In'
          AND (@DateFrom IS NULL OR l.TransactionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR l.TransactionDate <= @DateToEnd)
          AND (@ItemID IS NULL OR l.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (@SupplierID IS NULL OR poCtx.SupplierID = @SupplierID)
          AND (
              @ReportCode <> 'REC_MANUAL_RECEIPTS'
              OR ISNULL(l.ReferenceType, '') <> 'REPLENISHMENT'
          );

        SELECT @RowCount = COUNT(*) FROM @Receipts;

        SELECT
            @RowCount AS TotalReceipts,
            ISNULL(SUM(QuantityReceived), 0) AS TotalQtyReceived,
            ISNULL(SUM(CASE WHEN SourceDisplay = 'Manual receipt' THEN 1 ELSE 0 END), 0) AS ManualCount,
            ISNULL(SUM(CASE WHEN SignedStatus = 'Digitally signed' THEN 1 ELSE 0 END), 0) AS SignedCount
        FROM @Receipts;

        SELECT * FROM @Receipts ORDER BY TransactionDate DESC, InventoryLogID DESC;
    END
    ELSE IF @ReportCode = 'REC_RR_VS_PO'
    BEGIN
        DECLARE @Recon TABLE
        (
            POCode VARCHAR(20),
            DateIssued DATETIME2(0),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            POStatus VARCHAR(30),
            QuantityOrdered INT,
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            QuantityStocked INT,
            PendingToStock INT,
            OrderVariance INT
        );

        INSERT INTO @Recon
        SELECT
            'PO-' + RIGHT('0000' + CAST(po.POID AS VARCHAR(10)), 4),
            po.DateIssued,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            po.Status,
            po.QuantityOrdered,
            ISNULL(d.Delivered, 0),
            ISNULL(d.Accepted, 0),
            ISNULL(d.Rejected, 0),
            ISNULL(m.Stocked, 0),
            ISNULL(d.Accepted, 0) - ISNULL(m.Stocked, 0),
            po.QuantityOrdered - ISNULL(m.Stocked, 0)
        FROM dbo.PURCHASE_ORDERS po
        INNER JOIN dbo.PURCHASE_REQUESTS pr ON pr.PRID = po.PRID
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        OUTER APPLY
        (
            SELECT
                SUM(dd.QuantityDelivered) AS Delivered,
                SUM(dd.QuantityAccepted) AS Accepted,
                SUM(dd.QuantityRejected) AS Rejected
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
            WHERE dr.POID = po.POID
        ) d
        OUTER APPLY
        (
            SELECT SUM(rmd.QuantityReceived) AS Stocked
            FROM dbo.DELIVERY_RECEIPTS dr
            INNER JOIN dbo.RECEIVING_MEMOS rm ON rm.DRID = dr.DRID
            INNER JOIN dbo.RECEIVING_MEMO_DETAILS rmd ON rmd.RMID = rm.RMID
            WHERE dr.POID = po.POID AND rm.InventoryUpdated = 1
        ) m
        WHERE po.Status NOT IN ('Rejected', 'Cancelled')
          AND (@DateFrom IS NULL OR po.DateIssued >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR po.DateIssued <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (NULLIF(@Status, '') IS NULL OR po.Status = @Status);

        SELECT @RowCount = COUNT(*) FROM @Recon;

        SELECT
            @RowCount AS TotalPOs,
            ISNULL(SUM(QuantityOrdered), 0) AS TotalOrdered,
            ISNULL(SUM(QuantityAccepted), 0) AS TotalAccepted,
            ISNULL(SUM(QuantityStocked), 0) AS TotalStocked,
            ISNULL(SUM(OrderVariance), 0) AS TotalVariance
        FROM @Recon;

        SELECT * FROM @Recon ORDER BY DateIssued DESC;
    END
    ELSE IF @ReportCode = 'REC_REJECTED_ITEMS'
    BEGIN
        DECLARE @Rej TABLE
        (
            DRCode VARCHAR(20),
            DeliveryDate DATETIME2(0),
            POCode VARCHAR(20),
            SupplierDRNumber NVARCHAR(100),
            SupplierName NVARCHAR(200),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            QuantityDelivered INT,
            QuantityAccepted INT,
            QuantityRejected INT,
            DRStatus VARCHAR(30),
            Remarks NVARCHAR(1000)
        );

        INSERT INTO @Rej
        SELECT
            'DR-' + RIGHT('0000' + CAST(dr.DRID AS VARCHAR(10)), 4),
            dr.DeliveryDate,
            'PO-' + RIGHT('0000' + CAST(dr.POID AS VARCHAR(10)), 4),
            tr.SupplierDRNumber,
            s.SupplierName,
            i.ItemCode,
            i.ItemName,
            dd.QuantityDelivered,
            dd.QuantityAccepted,
            dd.QuantityRejected,
            dr.Status,
            ISNULL(dd.Remarks, dr.Notes)
        FROM dbo.DELIVERY_RECEIPTS dr
        INNER JOIN dbo.DELIVERY_RECEIPT_DETAILS dd ON dd.DRID = dr.DRID
        INNER JOIN dbo.PURCHASE_ORDERS po ON po.POID = dr.POID
        INNER JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        INNER JOIN dbo.ITEMS i ON i.ItemID = dd.ItemID
        LEFT JOIN dbo.PURCHASING_DR_TRACKING tr ON tr.DRID = dr.DRID
        WHERE dd.QuantityRejected > 0
          AND (@DateFrom IS NULL OR dr.DeliveryDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR dr.DeliveryDate <= @DateToEnd)
          AND (@SupplierID IS NULL OR po.SupplierID = @SupplierID)
          AND (@ItemID IS NULL OR dd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID);

        SELECT @RowCount = COUNT(*) FROM @Rej;

        SELECT
            @RowCount AS RejectedLines,
            ISNULL(SUM(QuantityDelivered), 0) AS TotalDelivered,
            ISNULL(SUM(QuantityRejected), 0) AS TotalRejected
        FROM @Rej;

        SELECT * FROM @Rej ORDER BY DeliveryDate DESC;
    END
    ELSE
        THROW 50809, 'Unknown receiving report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   10. REPLENISHMENT REPORTS
 */

CREATE   PROCEDURE dbo.usp_Report_Replenishment
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
    OR (
        @RoleName NOT IN (N'Admin', N'Manager')
        AND NOT EXISTS
        (
            SELECT 1 FROM dbo.USERS u
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ActorUserID AND p.PermissionCode IN ('inventory.view', 'purchasing.view', 'receiving.view')
        )
    )
        THROW 50807, 'You do not have permission to view replenishment reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; ItemID=', ISNULL(CAST(@ItemID AS VARCHAR(20)), 'All'),
        '; Status=', ISNULL(@Status, 'All')
    );

    DECLARE @RepFs TABLE
    (
        RepFID INT,
        RepFCode VARCHAR(20),
        DateGenerated DATETIME2(0),
        ItemCode VARCHAR(30),
        ItemName NVARCHAR(200),
        CategoryName NVARCHAR(100),
        QuantityNeeded INT,
        QuantityReceived INT,
        RemainingQuantity INT,
        Status VARCHAR(30),
        OriginRFCode VARCHAR(20),
        LinkedPRCode VARCHAR(20),
        LinkedPOCode VARCHAR(20),
        POStatus VARCHAR(30),
        SupplierName NVARCHAR(200)
    );

    INSERT INTO @RepFs
    SELECT
        rr.RepFID,
        'RepF-' + RIGHT('0000' + CAST(rr.RepFID AS VARCHAR(10)), 4),
        rr.DateGenerated,
        i.ItemCode,
        i.ItemName,
        ISNULL(c.CategoryName, N'Uncategorized'),
        rr.QuantityNeeded,
        rr.QuantityReceived,
        rr.QuantityNeeded - rr.QuantityReceived,
        rr.Status,
        CASE WHEN rr.OriginRequisitionID IS NOT NULL
             THEN 'RF-' + RIGHT('0000' + CAST(rr.OriginRequisitionID AS VARCHAR(10)), 4)
             ELSE N'Reorder Point' END,
        CASE WHEN link.PRID IS NOT NULL
             THEN 'PR-' + RIGHT('0000' + CAST(link.PRID AS VARCHAR(10)), 4)
             ELSE N'—' END,
        CASE WHEN link.POID IS NOT NULL
             THEN 'PO-' + RIGHT('0000' + CAST(link.POID AS VARCHAR(10)), 4)
             ELSE N'—' END,
        ISNULL(link.POStatus, N'No PO'),
        ISNULL(link.SupplierName, N'—')
    FROM dbo.REPLENISHMENT_REQUESTS rr
    INNER JOIN dbo.ITEMS i ON i.ItemID = rr.ItemID
    LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
    OUTER APPLY
    (
        SELECT TOP (1)
            pr.PRID,
            po.POID,
            po.Status AS POStatus,
            s.SupplierName
        FROM dbo.PURCHASE_REQUESTS pr
        LEFT JOIN dbo.PURCHASE_ORDERS po ON po.PRID = pr.PRID
        LEFT JOIN dbo.SUPPLIERS s ON s.SupplierID = po.SupplierID
        WHERE pr.RepFID = rr.RepFID
        ORDER BY po.POID DESC, pr.PRID DESC
    ) link
    WHERE (@DateFrom IS NULL OR rr.DateGenerated >= CAST(@DateFrom AS DATETIME2(0)))
      AND (@DateToEnd IS NULL OR rr.DateGenerated <= @DateToEnd)
      AND (@ItemID IS NULL OR rr.ItemID = @ItemID)
      AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
      AND (NULLIF(@Status, '') IS NULL OR rr.Status = @Status);

    DECLARE @RowCount INT;
    SELECT @RowCount = COUNT(*) FROM @RepFs;

    SELECT
        @RowCount AS TotalRepFs,
        ISNULL(SUM(CASE WHEN Status = 'Pending' THEN 1 ELSE 0 END), 0) AS PendingCount,
        ISNULL(SUM(CASE WHEN Status = 'Processed' THEN 1 ELSE 0 END), 0) AS ProcessedCount,
        ISNULL(SUM(QuantityNeeded), 0) AS TotalNeeded,
        ISNULL(SUM(RemainingQuantity), 0) AS TotalRemaining
    FROM @RepFs;

    SELECT * FROM @RepFs
    ORDER BY
        CASE WHEN @ReportCode = 'REPF_STATUS_TRACKING' THEN Status END ASC,
        DateGenerated DESC,
        RepFID DESC;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   8. REQUISITION REPORTS (ROW-LEVEL SCOPED)
 */

CREATE   PROCEDURE dbo.usp_Report_Requisition
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL,
    @DepartmentRole NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
        THROW 50805, 'You do not have permission to view requisition reports.', 1;

    /* Row-level scoping: Staff sees only their own requisitions. */
    DECLARE @ScopedRequestorID INT =
        CASE WHEN @RoleName = N'Staff' THEN @ActorUserID ELSE @RequestorUserID END;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; Requestor=', ISNULL(CAST(@ScopedRequestorID AS VARCHAR(20)), 'All'),
        '; Role=', ISNULL(@DepartmentRole, 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('REQ_REGISTER', 'REQ_FULFILLMENT_RATE')
    BEGIN
        DECLARE @Reqs TABLE
        (
            RequisitionID INT,
            RFCode VARCHAR(20),
            RequestDate DATETIME2(0),
            RequiredDate DATE,
            RequestorName NVARCHAR(200),
            RequestorRole NVARCHAR(100),
            ApproverName NVARCHAR(200),
            Status VARCHAR(30),
            LineCount INT,
            TotalRequested INT,
            TotalApproved INT,
            TotalFulfilled INT,
            FulfillmentRatePct DECIMAL(6,2),
            ApprovedDate DATETIME2(0),
            Justification NVARCHAR(500)
        );

        INSERT INTO @Reqs
        SELECT
            r.RequisitionID,
            'RF-' + RIGHT('0000' + CAST(r.RequisitionID AS VARCHAR(10)), 4),
            r.RequestDate,
            r.RequiredDate,
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            CASE WHEN ap.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(ap.FirstName, ' ', ap.LastName))) ELSE N'—' END,
            r.Status,
            COUNT(rd.RequisitionDetailID),
            ISNULL(SUM(rd.QuantityRequested), 0),
            ISNULL(SUM(ISNULL(rd.QuantityApproved, 0)), 0),
            ISNULL(SUM(CASE WHEN rd.Status = 'Fulfilled' THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested) ELSE 0 END), 0),
            CASE
                WHEN ISNULL(SUM(rd.QuantityRequested), 0) > 0
                    THEN CAST(ISNULL(SUM(CASE WHEN rd.Status = 'Fulfilled' THEN ISNULL(rd.QuantityApproved, rd.QuantityRequested) ELSE 0 END), 0) * 100.0
                        / SUM(rd.QuantityRequested) AS DECIMAL(6,2))
                ELSE 0
            END,
            r.ApprovedDate,
            r.Justification
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.USERS ap ON ap.UserID = r.DepartmentHeadUserID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (NULLIF(@Status, '') IS NULL OR r.Status = @Status)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY
            r.RequisitionID, r.RequestDate, r.RequiredDate,
            req.FirstName, req.LastName, reqRole.RoleName,
            ap.UserID, ap.FirstName, ap.LastName,
            r.Status, r.ApprovedDate, r.Justification;

        SELECT @RowCount = COUNT(*) FROM @Reqs;

        SELECT
            @RowCount AS TotalRequisitions,
            ISNULL(SUM(TotalRequested), 0) AS TotalRequestedUnits,
            ISNULL(SUM(TotalApproved), 0) AS TotalApprovedUnits,
            ISNULL(SUM(TotalFulfilled), 0) AS TotalFulfilledUnits,
            CASE
                WHEN ISNULL(SUM(TotalRequested), 0) > 0
                    THEN CAST(ISNULL(SUM(TotalFulfilled), 0) * 100.0 / SUM(TotalRequested) AS DECIMAL(6,2))
                ELSE 0
            END AS OverallFulfillmentPct
        FROM @Reqs;

        SELECT * FROM @Reqs ORDER BY RequestDate DESC, RequisitionID DESC;
    END
    ELSE IF @ReportCode = 'REQ_STATUS_SUMMARY'
    BEGIN
        DECLARE @Summary TABLE
        (
            Status VARCHAR(30),
            RequisitionCount INT,
            TotalRequested INT,
            TotalApproved INT,
            SharePct DECIMAL(6,2)
        );

        DECLARE @TotalReqCount INT;
        SELECT @TotalReqCount = COUNT(DISTINCT r.RequisitionID)
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID);

        INSERT INTO @Summary
        SELECT
            r.Status,
            COUNT(DISTINCT r.RequisitionID),
            ISNULL(SUM(rd.QuantityRequested), 0),
            ISNULL(SUM(ISNULL(rd.QuantityApproved, 0)), 0),
            CASE
                WHEN @TotalReqCount > 0
                    THEN CAST(COUNT(DISTINCT r.RequisitionID) * 100.0 / @TotalReqCount AS DECIMAL(6,2))
                ELSE 0
            END
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        WHERE (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY r.Status;

        SELECT @RowCount = COUNT(*) FROM @Summary;

        SELECT
            ISNULL(@TotalReqCount, 0) AS TotalRequisitions,
            ISNULL(SUM(TotalRequested), 0) AS TotalRequested,
            ISNULL(SUM(TotalApproved), 0) AS TotalApproved
        FROM @Summary;

        SELECT * FROM @Summary ORDER BY RequisitionCount DESC, Status ASC;
    END
    ELSE IF @ReportCode = 'REQ_REQUESTOR_USAGE'
    BEGIN
        DECLARE @Usage TABLE
        (
            RequestorName NVARCHAR(200),
            DepartmentRole NVARCHAR(100),
            CategoryName NVARCHAR(100),
            ItemCode VARCHAR(30),
            ItemName NVARCHAR(200),
            RequisitionCount INT,
            QuantityRequested INT,
            QuantityApproved INT,
            EstimatedCost DECIMAL(18,2)
        );

        INSERT INTO @Usage
        SELECT
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            ISNULL(c.CategoryName, N'Uncategorized'),
            i.ItemCode,
            i.ItemName,
            COUNT(DISTINCT r.RequisitionID),
            SUM(rd.QuantityRequested),
            SUM(ISNULL(rd.QuantityApproved, 0)),
            SUM(CAST(ISNULL(rd.QuantityApproved, rd.QuantityRequested) AS DECIMAL(18,2)) * i.UnitPrice)
        FROM dbo.REQUISITIONS r
        INNER JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
        INNER JOIN dbo.ITEMS i ON i.ItemID = rd.ItemID
        LEFT JOIN dbo.CATEGORIES c ON c.CategoryID = i.CategoryID
        INNER JOIN dbo.USERS req ON req.UserID = r.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        WHERE r.Status IN ('Approved', 'Fulfilled')
          AND (@ScopedRequestorID IS NULL OR r.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR r.RequestDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR r.RequestDate <= @DateToEnd)
          AND (@ItemID IS NULL OR rd.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
        GROUP BY
            req.FirstName, req.LastName, reqRole.RoleName,
            c.CategoryName, i.ItemCode, i.ItemName;

        SELECT @RowCount = COUNT(*) FROM @Usage;

        SELECT
            @RowCount AS UsageLines,
            ISNULL(SUM(QuantityRequested), 0) AS TotalRequested,
            ISNULL(SUM(QuantityApproved), 0) AS TotalApproved,
            ISNULL(SUM(EstimatedCost), 0) AS TotalEstimatedCost
        FROM @Usage;

        SELECT * FROM @Usage ORDER BY EstimatedCost DESC, RequestorName ASC;
    END
    ELSE
        THROW 50809, 'Unknown requisition report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* ============================================================
   3. REQUISITION APPROVAL & REJECTION â€” SELF-DECISION GUARD
      AND NO inventory.update REQUIREMENT
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Requisition_Approve
    @RequisitionID INT,
    @ApproverUserID INT,
    @Signature NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RequestorUserID INT;
    DECLARE @ItemID INT;
    DECLARE @QuantityRequested INT;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.approve'
        )
        BEGIN
            THROW 50001, 'You do not have permission to approve requisitions.', 1;
        END;

        IF NULLIF(LTRIM(RTRIM(@Signature)), N'') IS NULL
            THROW 50004,
                'A signature is required before approving the requisition.',
                1;

        IF @Signature NOT LIKE N'data:image/%'
            THROW 50005,
                'The signature image is not valid.',
                1;

        IF LEN(@Signature) > 2000000
            THROW 50006,
                'The signature image is too large.',
                1;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50002, 'Requisition not found or is no longer pending.', 1;
        END;

        IF @RequestorUserID = @ApproverUserID
        BEGIN
            THROW 50007, 'You cannot approve your own requisition. Another authorized approver must review it.', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
        )
        BEGIN
            THROW 50003, 'This requisition has no items.', 1;
        END;

        UPDATE dbo.REQUISITIONS
        SET
            Status = 'Approved',
            DepartmentHeadUserID = @ApproverUserID,
            ApprovalSignatureData = @Signature,
            ApprovedDate = SYSDATETIME()
        WHERE RequisitionID = @RequisitionID;

        UPDATE dbo.REQUISITION_DETAILS
        SET
            QuantityApproved = QuantityRequested
        WHERE RequisitionID = @RequisitionID;

        DECLARE requisition_items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemID, QuantityRequested
            FROM dbo.REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
            ORDER BY RequisitionDetailID;

        OPEN requisition_items;

        FETCH NEXT FROM requisition_items
        INTO @ItemID, @QuantityRequested;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Inventory_IssueStock
                @ActorUserID = @ApproverUserID,
                @ItemID = @ItemID,
                @QuantityRequested = @QuantityRequested,
                @RequisitionID = @RequisitionID;

            FETCH NEXT FROM requisition_items
            INTO @ItemID, @QuantityRequested;
        END;

        CLOSE requisition_items;
        DEALLOCATE requisition_items;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID,
            TargetUserID,
            ActionType,
            Description
        )
        VALUES
        (
            @ApproverUserID,
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Approved requisition #' + CAST(@RequisitionID AS VARCHAR(20))
        );

        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID
        )
        VALUES
        (
            @RequestorUserID,
            'REQUISITION_APPROVED',
            'Requisition Approved',
            'Your requisition #' + CAST(@RequisitionID AS VARCHAR(20)) + ' has been approved.',
            'REQUISITION',
            @RequisitionID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'requisition_items') >= 0
            CLOSE requisition_items;

        IF CURSOR_STATUS('local', 'requisition_items') >= -1
            DEALLOCATE requisition_items;

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

/* Requisition approval + generic signature. Ang existing
   usp_Requisition_Approve kay nag-store pa sa legacy columns para sa
   AR print, ug kining wrapper kay nagdugang sa DOCUMENT_SIGNATURES. */
CREATE   PROCEDURE dbo.usp_Requisition_ApproveWithSignature
    @RequisitionID INT,
    @ApproverUserID INT,
    @SignatureImage NVARCHAR(MAX),
    @Confirmed BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Confirmed, 0) <> 1
        THROW 50708,
            'Please confirm your signature before approving the requisition.',
            1;

    IF NULLIF(LTRIM(RTRIM(@SignatureImage)), N'') IS NULL
        THROW 50735,
            'A signature is required to approve a requisition.',
            1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Requisition_Approve
            @RequisitionID = @RequisitionID,
            @ApproverUserID = @ApproverUserID,
            @Signature = @SignatureImage;

        EXEC dbo.usp_DocumentSignature_Sign
            @ActorUserID = @ApproverUserID,
            @DocumentType = 'REQUISITION',
            @DocumentID = @RequisitionID,
            @Stage = 'Approved',
            @SignatureImage = @SignatureImage,
            @Confirmed = @Confirmed,
            @ReturnResult = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE   PROCEDURE dbo.usp_Requisition_Cancel
    @RequisitionID INT,
    @ActorUserID INT,
    @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @RequestorUserID INT,
            @ActorRole NVARCHAR(50),
            @CanApprove BIT = 0;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved');

        IF @RequestorUserID IS NULL
            THROW 50200, 'The pending or approved requisition could not be found.', 1;

        SELECT
            @ActorRole = r.RoleName,
            @CanApprove = MAX(CASE WHEN p.PermissionCode = N'requisitions.approve' THEN 1 ELSE 0 END)
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        LEFT JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        LEFT JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND u.IsActive = 1
        GROUP BY r.RoleName;

        IF @ActorRole IS NULL
            THROW 50201, 'The user account was not found or is inactive.', 1;

        IF @ActorUserID <> @RequestorUserID AND ISNULL(@CanApprove, 0) = 0
            THROW 50202, 'You are not authorized to cancel this requisition.', 1;

        DECLARE @ReservationID INT, @DetailID INT, @Qty INT, @ItemID INT, @OnHand INT;
        DECLARE cancel_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT ir.ReservationID, ir.RequisitionDetailID, ir.QuantityReserved, rd.ItemID
            FROM dbo.INVENTORY_RESERVATIONS ir
            INNER JOIN dbo.REQUISITION_DETAILS rd ON rd.RequisitionDetailID = ir.RequisitionDetailID
            WHERE rd.RequisitionID = @RequisitionID AND ir.Status = 'Active';

        OPEN cancel_cursor;
        FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @OnHand = QuantityOnHand
            FROM dbo.INVENTORY WITH (UPDLOCK, HOLDLOCK)
            WHERE ItemID = @ItemID AND QuantityReserved >= @Qty;

            IF @OnHand IS NULL
                THROW 50203, 'The reserved quantity in inventory is inconsistent.', 1;

            UPDATE dbo.INVENTORY
            SET QuantityReserved = QuantityReserved - @Qty, LastUpdated = SYSDATETIME()
            WHERE ItemID = @ItemID;

            UPDATE dbo.INVENTORY_RESERVATIONS
            SET Status = 'Cancelled'
            WHERE ReservationID = @ReservationID AND Status = 'Active';

            INSERT INTO dbo.INVENTORY_LOGS
                (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity, NewQuantity, ReferenceType, ReferenceID, Remarks)
            VALUES
                (@ItemID, @ActorUserID, 'Release', 0, @OnHand, @OnHand, 'Reservation', @ReservationID,
                 'This reservation was released due to cancellation.');
            FETCH NEXT FROM cancel_cursor INTO @ReservationID, @DetailID, @Qty, @ItemID;
        END;

        CLOSE cancel_cursor;
        DEALLOCATE cancel_cursor;

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = 'Cancelled'
        WHERE RequisitionID = @RequisitionID AND Status IN ('Pending', 'Approved', 'Partially Fulfilled');

        UPDATE dbo.REQUISITIONS
        SET Status = 'Cancelled', RejectionReason = @Reason
        WHERE RequisitionID = @RequisitionID;

        UPDATE pr
        SET Status = 'Cancelled'
        FROM dbo.PURCHASE_REQUESTS pr
        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
        WHERE rr.OriginRequisitionID = @RequisitionID
          AND pr.Status IN ('Open', 'Pending Approval', 'Approved', 'Rejected')
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PURCHASE_ORDERS po
              WHERE po.Status NOT IN ('Rejected', 'Cancelled')
                AND
                (
                    po.PRID = pr.PRID
                    OR EXISTS
                    (
                        SELECT 1 FROM dbo.PO_PR_Mapping m
                        WHERE m.POID = po.POID AND m.PRID = pr.PRID
                    )
                )
          );

        UPDATE dbo.REPLENISHMENT_REQUESTS
        SET Status = 'Cancelled'
        WHERE OriginRequisitionID = @RequisitionID
          AND Status = 'Pending';

        UPDATE dbo.NOTIFICATIONS
        SET IsRead = 1, ReadAt = SYSDATETIME()
        WHERE NotificationType IN (N'REQUISITION_ALLOCATED', N'STOCK_ALLOCATED', N'STOCK_SHORTAGE')
          AND RelatedEntityType = N'REQUISITION'
          AND RelatedEntityID = @RequisitionID
          AND IsRead = 0;

        INSERT INTO dbo.USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @RequestorUserID, 'REQUISITION_CANCELLED',
                CONCAT('Requisition ID: ', @RequisitionID, '. ', COALESCE(@Reason, 'No additional reason provided.')));

        IF @ActorUserID <> @RequestorUserID
        BEGIN
            INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
            VALUES (@RequestorUserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
                    CONCAT('Your requisition #', @RequisitionID,
                           ' was cancelled by ', @ActorRole, '. ',
                           COALESCE(@Reason, '')),
                    'REQUISITION', @RequisitionID, 0, SYSDATETIME());
        END;

        /* Notify approvers and inventory staff (who have requisitions.view), excluding Purchasing Staff */
        INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
        SELECT DISTINCT u.UserID, 'REQUISITION_CANCELLED', 'Requisition cancelled',
               CONCAT('Requisition #', @RequisitionID, ' was cancelled. ',
                      COALESCE(@Reason, '')),
               'REQUISITION', @RequisitionID, 0, SYSDATETIME()
        FROM dbo.USERS u
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
        WHERE u.IsActive = 1
          AND u.UserID <> @ActorUserID
          AND u.UserID <> @RequestorUserID
          AND EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode IN (N'requisitions.approve', N'inventory.update')
          )
          AND EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode = N'requisitions.view'
          );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'cancel_cursor') >= 0 CLOSE cancel_cursor;
        IF CURSOR_STATUS('local', 'cancel_cursor') >= -1 DEALLOCATE cancel_cursor;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* 
   2. REQUISITION FORM PRINT — include Received By from completed AR
 */

CREATE   PROCEDURE dbo.usp_Requisition_GetPrint
    @ActorUserID INT,
    @RequisitionID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp
            ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p
            ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode IN
          (
              'requisitions.view',
              'requisitions.create',
              'requisitions.approve'
          )
    )
        THROW 50602,
            'You do not have permission to print requisition forms.',
            1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.REQUISITIONS
        WHERE RequisitionID = @RequisitionID
    )
        RETURN;

    /* Result set 1 requisition header + completed delivery receipt sign-off. */
    SELECT
        r.RequisitionID,
        LTRIM(RTRIM(CONCAT(
            requestor.FirstName, ' ', requestor.LastName
        ))) AS RequestorName,
        requestor.Email AS RequestorEmail,
        CASE
            WHEN head.UserID IS NULL THEN NULL
            ELSE LTRIM(RTRIM(CONCAT(
                head.FirstName, ' ', head.LastName
            )))
        END AS DepartmentHeadName,
        r.RequestDate,
        r.RequiredDate,
        r.Status,
        r.Justification,
        r.RejectionReason,
        r.ApprovedDate,
        r.ApprovalSignatureData,
        r.ArchivedAt,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonName'
        ) AS SalonName,
        (
            SELECT SettingValue
            FROM dbo.SYSTEM_SETTINGS
            WHERE SettingKey = 'SalonTagline'
        ) AS SalonTagline,
        del.ReceivedByName,
        del.ReceivedDate,
        del.ReceivedSignatureData
    FROM dbo.REQUISITIONS r
    INNER JOIN dbo.USERS requestor
        ON requestor.UserID = r.RequestorUserID
    LEFT JOIN dbo.USERS head
        ON head.UserID = r.DepartmentHeadUserID
    OUTER APPLY
    (
        SELECT TOP (1)
            LTRIM(RTRIM(CONCAT(su.FirstName, ' ', su.LastName))) AS ReceivedByName,
            d.SignedDate AS ReceivedDate,
            d.ESignatureData AS ReceivedSignatureData
        FROM dbo.DELIVERIES d
        LEFT JOIN dbo.USERS su
            ON su.UserID = ISNULL(d.SignedByUserID, d.RequestorUserID)
        WHERE d.RequisitionID = r.RequisitionID
          AND d.Status = N'Completed'
        ORDER BY d.SignedDate DESC, d.DeliveryID DESC
    ) del
    WHERE r.RequisitionID = @RequisitionID;

    /* Result set 2 requisition line items. */
    SELECT
        rd.RequisitionDetailID,
        i.ItemCode,
        i.ItemName,
        i.UnitOfMeasure,
        rd.QuantityRequested,
        rd.QuantityApproved,
        rd.Status AS DetailStatus
    FROM dbo.REQUISITION_DETAILS rd
    INNER JOIN dbo.ITEMS i
        ON i.ItemID = rd.ItemID
    WHERE rd.RequisitionID = @RequisitionID
    ORDER BY rd.RequisitionDetailID;
END;
GO

CREATE   PROCEDURE usp_Requisition_GetStaleReservations
    @DaysOld INT = 7
AS
BEGIN
    SET NOCOUNT ON;

    IF @DaysOld < 1
        THROW 50210, 'The number of days must be at least one.', 1;

    SELECT
        r.RequisitionID,
        r.RequestorUserID,
        r.RequestDate,
        r.RequiredDate,
        r.Status AS RequisitionStatus,
        rd.RequisitionDetailID,
        rd.ItemID,
        ir.ReservationID,
        ir.QuantityReserved,
        ir.ReservationDate,
        ir.Status AS ReservationStatus
    FROM REQUISITIONS r
    INNER JOIN REQUISITION_DETAILS rd ON rd.RequisitionID = r.RequisitionID
    LEFT JOIN INVENTORY_RESERVATIONS ir
        ON ir.RequisitionDetailID = rd.RequisitionDetailID AND ir.Status = 'Active'
    WHERE r.Status IN ('Pending', 'Approved')
      AND r.RequestDate < DATEADD(DAY, -@DaysOld, SYSDATETIME())
    ORDER BY r.RequestDate, r.RequisitionID, rd.RequisitionDetailID;
END;
GO

CREATE   PROCEDURE dbo.usp_Requisition_Reject
    @RequisitionID INT,
    @RejectorUserID INT,
    @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RequestorUserID INT;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.USERS u
            INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID AND r.IsActive = 1
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE u.UserID = @RejectorUserID
              AND u.IsActive = 1
              AND p.PermissionCode = N'requisitions.reject'
        )
        BEGIN
            THROW 50004, 'You do not have permission to reject requisitions.', 1;
        END;

        IF @Reason IS NULL OR LEN(LTRIM(RTRIM(@Reason))) = 0
        BEGIN
            THROW 50005, 'A rejection reason is required.', 1;
        END;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM dbo.REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50006, 'Requisition not found or is no longer pending.', 1;
        END;

        IF @RequestorUserID = @RejectorUserID
        BEGIN
            THROW 50008, 'You cannot reject your own requisition. Another authorized approver must review it.', 1;
        END;

        UPDATE dbo.REQUISITIONS
        SET
            Status = 'Rejected',
            RejectionReason = @Reason,
            DepartmentHeadUserID = @RejectorUserID
        WHERE RequisitionID = @RequisitionID;

        UPDATE dbo.REQUISITION_DETAILS
        SET Status = 'Rejected'
        WHERE RequisitionID = @RequisitionID;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID,
            TargetUserID,
            ActionType,
            Description
        )
        VALUES
        (
            @RejectorUserID,
            @RequestorUserID,
            'REQUISITION_REJECTED',
            'Rejected requisition #' + CAST(@RequisitionID AS VARCHAR(20))
        );

        INSERT INTO dbo.NOTIFICATIONS
        (
            RecipientUserID,
            NotificationType,
            Title,
            Message,
            RelatedEntityType,
            RelatedEntityID
        )
        VALUES
        (
            @RequestorUserID,
            'REQUISITION_REJECTED',
            'Requisition Rejected',
            'Your requisition #' + CAST(@RequisitionID AS VARCHAR(20))
                + ' was rejected. Reason: ' + @Reason,
            'REQUISITION',
            @RequisitionID
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

/* =========================================================
   1. RELEASE RESERVATIONS BEFORE REVISION
   ========================================================= */

CREATE   PROCEDURE dbo.usp_Requisition_ReleaseForRevision
    @RequisitionID INT,
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ReservationID INT, @Quantity INT, @ItemID INT;
    DECLARE @OnHand INT, @Reserved INT;

    DECLARE release_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT ir.ReservationID, ir.QuantityReserved, rd.ItemID
        FROM dbo.INVENTORY_RESERVATIONS ir
        INNER JOIN dbo.REQUISITION_DETAILS rd
            ON rd.RequisitionDetailID = ir.RequisitionDetailID
        WHERE rd.RequisitionID = @RequisitionID
          AND ir.Status = 'Active';

    OPEN release_cursor;
    FETCH NEXT FROM release_cursor INTO @ReservationID, @Quantity, @ItemID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @OnHand = QuantityOnHand, @Reserved = QuantityReserved
        FROM dbo.INVENTORY WITH (UPDLOCK, HOLDLOCK)
        WHERE ItemID = @ItemID;

        IF @Reserved IS NULL OR @Reserved < @Quantity
            THROW 50210, 'The reserved quantity for this requisition is inconsistent.', 1;

        UPDATE dbo.INVENTORY
        SET QuantityReserved = QuantityReserved - @Quantity,
            LastUpdated = SYSDATETIME()
        WHERE ItemID = @ItemID;

        UPDATE dbo.INVENTORY_RESERVATIONS
        SET Status = 'Cancelled'
        WHERE ReservationID = @ReservationID AND Status = 'Active';

        INSERT INTO dbo.INVENTORY_LOGS
            (ItemID, UserID, TransactionType, QuantityChange, PreviousQuantity,
             NewQuantity, ReferenceType, ReferenceID, Remarks, TransactionDate)
        VALUES
            (@ItemID, @ActorUserID, 'Release', 0, @OnHand, @OnHand,
             'Reservation', @ReservationID,
             'This reservation was released because the requisition is being revised.',
             SYSDATETIME());

        FETCH NEXT FROM release_cursor INTO @ReservationID, @Quantity, @ItemID;
    END;

    CLOSE release_cursor;
    DEALLOCATE release_cursor;

    -- Kani nga PRs kay wala nay active PO, so i-cancel na lang.
    UPDATE pr
    SET Status = 'Cancelled'
    FROM dbo.PURCHASE_REQUESTS pr
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr ON rr.RepFID = pr.RepFID
    WHERE rr.OriginRequisitionID = @RequisitionID
      AND pr.Status IN ('Open', 'Pending Approval', 'Approved', 'Rejected')
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.PURCHASE_ORDERS po
          WHERE po.Status NOT IN ('Rejected', 'Cancelled')
            AND
            (
                po.PRID = pr.PRID
                OR EXISTS
                (
                    SELECT 1 FROM dbo.PO_PR_Mapping m
                    WHERE m.POID = po.POID AND m.PRID = pr.PRID
                )
            )
      );

    -- Kani nga RepFs kay wala na'y requisition nga nagkinahanglan nila.
    UPDATE dbo.REPLENISHMENT_REQUESTS
    SET Status = 'Cancelled'
    WHERE OriginRequisitionID = @RequisitionID
      AND Status = 'Pending';

    -- Kani nga stale notifs kay wala na'y allocated nga i-deliver.
    UPDATE dbo.NOTIFICATIONS
    SET IsRead = 1, ReadAt = SYSDATETIME()
    WHERE NotificationType IN (N'REQUISITION_ALLOCATED', N'STOCK_ALLOCATED')
      AND RelatedEntityType = N'REQUISITION'
      AND RelatedEntityID = @RequisitionID
      AND IsRead = 0;
END;
GO

-- Kani nga procedure nag-himo og bag-ong role nga may permissions.
CREATE   PROCEDURE usp_Role_Create
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

-- Kani nga procedure nag-replace sa tanang permissions sa usa ka role.
CREATE   PROCEDURE usp_Role_SetPermissions
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

-- Kani nga procedure nag-update sa role details ug status.
CREATE   PROCEDURE usp_Role_Update
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

/* ------------------------------------------------------------
   ROLE & PERMISSION MANAGEMENT
   ------------------------------------------------------------ */

-- Kani nga procedure nagkuha sa tanang roles ug ilang permissions.
CREATE   PROCEDURE usp_Roles_GetAll
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

/* ============================================================
   2. GET EMAIL SETTINGS (Admin Settings UI â€” never exposes secret)
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Settings_GetEmailSettings
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

/* ================================================================
   5. GET PREFERENCES - key/value rows (branding + restock days).
   Gate: bisan kinsa nga active user (non-sensitive, gamiton sa
   sidebar branding sa tanang users).
   ================================================================ */
CREATE   PROCEDURE usp_Settings_GetPreferences
    @ActorUserID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ActorUserID AND IsActive = 1)
        THROW 50366, 'Your account is inactive or was not found.', 1;

    SELECT SettingKey, SettingValue FROM SYSTEM_SETTINGS ORDER BY SettingKey;
END;
GO

/* ================================================================
   3. GET UOMS - master list nga may item count kada unit.
   Gate: settings.manage OR inventory.create OR inventory.update
   (kini nga listahan kay gigamit sad sa inventory item form).
   ================================================================ */
CREATE   PROCEDURE usp_Settings_GetUoMs
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
          AND p.PermissionCode IN (N'settings.manage', N'inventory.create', N'inventory.update')
    )
        THROW 50360, 'You do not have permission to view the unit of measures.', 1;

    SELECT u.UomID, u.UomName, u.IsActive,
           (SELECT COUNT(*) FROM ITEMS i
            WHERE i.UnitOfMeasure = u.UomName COLLATE DATABASE_DEFAULT) AS ItemCount
    FROM UNIT_OF_MEASURES u
    ORDER BY u.UomName;
END;
GO

/* ============================================================
   3. SAVE EMAIL SETTINGS (Admin only â€” stores DPAPI ciphertext)
   ============================================================ */

CREATE   PROCEDURE dbo.usp_Settings_SaveEmailSettings
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

/* ================================================================
   6. SAVE PREFERENCES - upsert sa tulo ka settings keys.
   Gate: settings.manage. Validation: restock days 1-365,
   salon name/tagline dili empty.
   ================================================================ */
CREATE   PROCEDURE usp_Settings_SavePreferences
    @ActorUserID INT,
    @SalonName NVARCHAR(100),
    @SalonTagline NVARCHAR(60),
    @DefaultRestockDays INT
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
        THROW 50367, 'You do not have permission to manage system settings.', 1;

    IF NULLIF(LTRIM(RTRIM(@SalonName)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SalonTagline)), '') IS NULL
        THROW 50368, 'The salon name and tagline are required.', 1;

    IF @DefaultRestockDays IS NULL OR @DefaultRestockDays < 1 OR @DefaultRestockDays > 365
        THROW 50369, 'The default restock days must be between 1 and 365.', 1;

    -- Kani nga upsert block kay para sa tulo ka keys.
    MERGE SYSTEM_SETTINGS AS target
    USING (VALUES
        ('SalonName', @SalonName),
        ('SalonTagline', @SalonTagline),
        ('DefaultRestockDays', CAST(@DefaultRestockDays AS NVARCHAR(10)))
    ) AS source (SettingKey, SettingValue)
    ON target.SettingKey = source.SettingKey
    WHEN MATCHED THEN
        UPDATE SET SettingValue = source.SettingValue, UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (SettingKey, SettingValue) VALUES (source.SettingKey, source.SettingValue);
END;
GO

/* ================================================================
   4. SAVE UOM - create (UomID NULL) o update (name/status).
   Gate: settings.manage. Dili mo-delete - deactivate lang.
   ================================================================ */
CREATE   PROCEDURE usp_Settings_SaveUom
    @ActorUserID INT,
    @UomID INT = NULL,
    @UomName VARCHAR(20) = NULL,
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
          AND p.PermissionCode = N'settings.manage'
    )
        THROW 50361, 'You do not have permission to manage the unit of measures.', 1;

    DECLARE @CleanName VARCHAR(20) = NULLIF(LTRIM(RTRIM(@UomName)), '');

    IF @UomID IS NULL
    BEGIN
        -- Kani nga create path: kinahanglan ang name ug dili duplicate.
        IF @CleanName IS NULL
            THROW 50362, 'The unit of measure name is required.', 1;

        IF EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomName = @CleanName)
            THROW 50363, 'This unit of measure already exists.', 1;

        INSERT INTO UNIT_OF_MEASURES (UomName, IsActive) VALUES (@CleanName, 1);
        SELECT SCOPE_IDENTITY() AS UomID;
        RETURN;
    END;

    -- Kani nga update path: existing ra ang target.
    IF NOT EXISTS (SELECT 1 FROM UNIT_OF_MEASURES WHERE UomID = @UomID)
        THROW 50364, 'The unit of measure was not found.', 1;

    IF @CleanName IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM UNIT_OF_MEASURES
                   WHERE UomName = @CleanName AND UomID <> @UomID)
            THROW 50363, 'This unit of measure already exists.', 1;

        UPDATE UNIT_OF_MEASURES SET UomName = @CleanName WHERE UomID = @UomID;
    END;

    IF @IsActive IS NOT NULL
    BEGIN
        -- Kani nga block kay para dili ma-deactivate ang unit nga
        -- gigamit pa sa mga items (mabuwag ang item display).
        IF @IsActive = 0 AND EXISTS (
            SELECT 1 FROM ITEMS
            WHERE UnitOfMeasure = (SELECT UomName FROM UNIT_OF_MEASURES WHERE UomID = @UomID)
              AND IsActive = 1
        )
            THROW 50365, 'This unit of measure is still used by active items and cannot be deactivated.', 1;

        UPDATE UNIT_OF_MEASURES SET IsActive = @IsActive WHERE UomID = @UomID;
    END;
END;
GO

CREATE   PROCEDURE usp_Suppliers_GetAll
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
CREATE   PROCEDURE usp_Suppliers_Save
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

-- Kani nga procedure gitugotan ang Admin nga mo-reset sa password sa user.
CREATE   PROCEDURE usp_User_AdminResetPassword
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

/* ============================================================
   9. ROLE ASSIGNMENT â€” RESPECT users.assign_role AND ALLOW
      CUSTOM ROLES CREATED BY ADMIN (BLOCKING ONLY Admin ESCALATION)
   ============================================================ */

CREATE   PROCEDURE dbo.usp_User_AssignRole
    @ActorUserID INT,
    @TargetUserID INT,
    @NewRoleID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ActorActive BIT = 0;
    DECLARE @CanAssign BIT = 0;
    DECLARE @NewRole NVARCHAR(50);
    DECLARE @TargetRole NVARCHAR(50);

    SELECT
        @ActorActive = 1,
        @CanAssign = MAX(CASE WHEN p.PermissionCode = N'users.assign_role' THEN 1 ELSE 0 END)
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    INNER JOIN dbo.ROLE_PERMISSIONS rp
        ON rp.RoleID = u.RoleID
    INNER JOIN dbo.PERMISSIONS p
        ON p.PermissionID = rp.PermissionID
    WHERE u.UserID = @ActorUserID
      AND u.IsActive = 1;

    SELECT @NewRole = RoleName
    FROM dbo.ROLES
    WHERE RoleID = @NewRoleID
      AND IsActive = 1;

    SELECT @TargetRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
    WHERE u.UserID = @TargetUserID;

    IF ISNULL(@ActorActive, 0) = 0
        THROW 50001, 'Invalid or inactive account.', 1;

    IF ISNULL(@CanAssign, 0) = 0
        THROW 50002, 'You do not have permission to assign user roles.', 1;

    IF @NewRole IS NULL
        THROW 50003, 'Invalid role.', 1;

    IF @NewRole = N'Admin'
        THROW 50004, 'Admin role cannot be assigned through this procedure.', 1;

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

-- Kani nga procedure para i-update ang password hash sa user.
CREATE   PROCEDURE usp_User_ChangePassword
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

-- Kani nga procedure para mag-himo og bag-ong user account ang Admin.
CREATE   PROCEDURE usp_User_Create
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

-- Kani nga procedure para i-deactivate ang user nga dili i-delete ang historical records.
CREATE   PROCEDURE usp_User_Deactivate
    @ActorUserID INT,
    @TargetUserID INT,
    @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM USERS WHERE UserID = @ActorUserID AND IsActive = 1)
        THROW 50190, 'The actor does not exist or is inactive.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE USERS
        SET IsActive = 0
        WHERE UserID = @TargetUserID AND IsActive = 1;

        IF @@ROWCOUNT = 0
            THROW 50191, 'The active target user could not be found.', 1;

        INSERT INTO USER_AUDIT_LOGS (ActorUserID, TargetUserID, ActionType, Description)
        VALUES (@ActorUserID, @TargetUserID, 'USER_DEACTIVATED', @Reason);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Kani nga procedure nag-activate o nag-deactivate sa user account.
CREATE   PROCEDURE usp_User_SetActive
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

-- Kani nga procedure nag-update sa basic details ug role sa usa ka user.
CREATE   PROCEDURE usp_User_UpdateDetails
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

/* ============================================================
   V002 â€” User & Role Management
   Adds management procedures for user accounts and security roles.
   Conventions follow V001: permission checks inside each procedure,
   English error messages, audit rows in USER_AUDIT_LOGS.
   ============================================================ */

/* ------------------------------------------------------------
   USER MANAGEMENT
   ------------------------------------------------------------ */

-- Kani nga procedure nagkuha sa tanang user accounts para sa listahan.
CREATE   PROCEDURE usp_Users_GetAll
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

-- 7. TRIGGERS
CREATE   TRIGGER dbo.trg_DELIVERIES_AfterInsert_AutoMarkAllocatedNotifs
ON dbo.DELIVERIES
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga auto-mark kay para sa "action accomplished" principle:
    -- ang Generate AR mao ang action sa allocated-ready notifs, so
    -- mark read na ang tanan sa kana nga requisition.
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType = N'REQUISITION_ALLOCATED'
      AND n.RelatedEntityType = N'REQUISITION'
      AND n.IsRead = 0;
END;
GO

CREATE   TRIGGER dbo.trg_DELIVERIES_AutoMarkNotifications
ON dbo.DELIVERIES
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    /* 1. Clear discrepancy alerts once AR is re-issued (Generated) or Completed */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_DISCREPANCY'
      AND n.RelatedEntityType = N'DELIVERY'
      AND i.Status IN (N'Generated', N'Completed')
      AND n.IsRead = 0;

    /* 2. Clear re-issue alert once AR is Issued again or Completed */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_REISSUED'
      AND n.RelatedEntityType = N'DELIVERY'
      AND i.Status IN (N'Issued', N'Completed')
      AND n.IsRead = 0;

    /* 3. Clear issued alert once AR is Completed or an open discrepancy is noted */
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.DeliveryID = n.RelatedEntityID
    WHERE n.NotificationType = N'DELIVERY_ISSUED'
      AND n.RelatedEntityType = N'DELIVERY'
      AND (
          i.Status = N'Completed'
          OR (NULLIF(LTRIM(RTRIM(i.DiscrepancyNotes)), N'') IS NOT NULL AND i.DiscrepancyResolvedAt IS NULL)
      )
      AND n.IsRead = 0;
END;
GO

/* ================================================================
   3. TRIGGER: INVENTORY - auto-mark sa low-stock notifications
      kung ang item stock balik na sa ibabaw sa reorder point
      (pagkahuman sa receiving).
   ================================================================ */
CREATE   TRIGGER trg_INVENTORY_AutoMarkLowStockNotifications
ON INVENTORY
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga mark kay para sa LOW_STOCK notifs nga ang ilang item
    -- okay na: available (on hand - reserved) > reorder point.
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.ItemID = n.RelatedEntityID
    INNER JOIN ITEMS it ON it.ItemID = i.ItemID
    WHERE n.NotificationType = 'LOW_STOCK'
      AND n.RelatedEntityType = 'ITEM'
      AND n.IsRead = 0
      AND (i.QuantityOnHand - i.QuantityReserved) > it.ReorderPoint;
END;
GO

CREATE   TRIGGER dbo.trg_Purchasing_PONotifications
ON dbo.PURCHASE_ORDERS
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    /* New PO awaiting approval */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'PO_PENDING_APPROVAL',
        'Purchase order awaiting approval',
        CONCAT
        (
            'PO #',
            i.POID,
            ' is awaiting your review. Open Purchasing to approve or reject it.'
        ),
        'PURCHASE_ORDER',
        i.POID,
        0,
        SYSDATETIME()
    FROM inserted i
    LEFT JOIN deleted d
        ON d.POID = i.POID
    CROSS JOIN dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    WHERE i.Status = 'Pending Approval'
      AND
      (
          d.POID IS NULL
          OR d.Status <> i.Status
      )
      AND u.IsActive = 1
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = N'requisitions.approve'
      )
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = N'purchasing.view'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = u.UserID
            AND n.NotificationType = 'PO_PENDING_APPROVAL'
            AND n.RelatedEntityType = 'PURCHASE_ORDER'
            AND n.RelatedEntityID = i.POID
            AND n.IsRead = 0
      );

    /* Approved PO notification */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        u.UserID,
        'PO_APPROVED',
        'Purchase order approved',
        CONCAT
        (
            'PO #',
            i.POID,
            ' was approved. Open Purchasing to prepare the supplier order.'
        ),
        'PURCHASE_ORDER',
        i.POID,
        0,
        SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d
        ON d.POID = i.POID
       AND d.Status <> i.Status
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = i.PRID
    CROSS JOIN dbo.USERS u
    INNER JOIN dbo.ROLES r
        ON r.RoleID = u.RoleID
       AND r.IsActive = 1
    WHERE i.Status = 'Approved'
      AND u.IsActive = 1
      AND
      (
          u.UserID = pr.CreatedByUserID
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ROLE_PERMISSIONS rp
              INNER JOIN dbo.PERMISSIONS p
                  ON p.PermissionID = rp.PermissionID
              WHERE rp.RoleID = u.RoleID
                AND p.PermissionCode = 'purchasing.manage'
          )
      )
      AND EXISTS
      (
          SELECT 1
          FROM dbo.ROLE_PERMISSIONS rp
          INNER JOIN dbo.PERMISSIONS p
              ON p.PermissionID = rp.PermissionID
          WHERE rp.RoleID = u.RoleID
            AND p.PermissionCode = 'purchasing.view'
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = u.UserID
            AND n.NotificationType = 'PO_APPROVED'
            AND n.RelatedEntityType = 'PURCHASE_ORDER'
            AND n.RelatedEntityID = i.POID
            AND n.IsRead = 0
      );

    /* Rejected PO: notify the originating requestor (hold or revise) */

    INSERT INTO dbo.NOTIFICATIONS
    (
        RecipientUserID,
        NotificationType,
        Title,
        Message,
        RelatedEntityType,
        RelatedEntityID,
        IsRead,
        CreatedAt
    )
    SELECT DISTINCT
        rq.RequestorUserID,
        'PO_REJECTED',
        'Purchase order rejected',
        CONCAT
        (
            'The purchase order for requisition #',
            rq.RequisitionID,
            ' was rejected. Purchasing will revise the purchase request. ',
            'Hold, or update your request if the need has changed.'
        ),
        'REQUISITION',
        rq.RequisitionID,
        0,
        SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d
        ON d.POID = i.POID
       AND d.Status <> i.Status
    INNER JOIN dbo.PURCHASE_REQUESTS pr
        ON pr.PRID = i.PRID
    INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
        ON rr.RepFID = pr.RepFID
    INNER JOIN dbo.REQUISITIONS rq
        ON rq.RequisitionID = rr.OriginRequisitionID
    WHERE i.Status = 'Rejected'
      AND rq.RequestorUserID IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.NOTIFICATIONS n
          WHERE n.RecipientUserID = rq.RequestorUserID
            AND n.NotificationType = 'PO_REJECTED'
            AND n.RelatedEntityType = 'REQUISITION'
            AND n.RelatedEntityID = rq.RequisitionID
            AND n.IsRead = 0
      );

    /* Review is complete once the PO leaves Pending Approval */

    UPDATE n
    SET
        IsRead = 1,
        ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i
        ON i.POID = n.RelatedEntityID
    WHERE n.NotificationType = 'PO_PENDING_APPROVAL'
      AND n.RelatedEntityType = 'PURCHASE_ORDER'
      AND i.Status <> 'Pending Approval'
      AND n.IsRead = 0;

    /* Dispatch is complete once the PO is Sent to Supplier, Delivered, or Cancelled */

    UPDATE n
    SET
        IsRead = 1,
        ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i
        ON i.POID = n.RelatedEntityID
    WHERE n.NotificationType = 'PO_APPROVED'
      AND n.RelatedEntityType = 'PURCHASE_ORDER'
      AND i.Status IN ('Sent to Supplier', 'Partially Delivered', 'Delivered', 'Cancelled')
      AND n.IsRead = 0;
END;
GO

/* ============================================================
   2. PR REVISED -> CLEAR STALE PO REJECTION ALERTS
   ============================================================ */

CREATE   TRIGGER dbo.trg_Purchasing_PrRevision
ON dbo.PURCHASE_REQUESTS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Kung gi-reopen ang rejected PR para i-revise (Rejected -> Open),
        i-mark read ang daan nga PO_REJECTED notifications. Kini para
        wala nay stale rejection sa bell samtang naghimo na ang
        Purchasing sa bag-ong PO para reapproval.
    */

    UPDATE n
    SET
        IsRead = 1,
        ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    WHERE n.NotificationType = 'PO_REJECTED'
      AND n.IsRead = 0
      AND EXISTS
      (
          SELECT 1
          FROM inserted i
          INNER JOIN deleted d
              ON d.PRID = i.PRID
          WHERE i.Status = 'Open'
            AND d.Status = 'Rejected'
            AND
            (
                (
                    n.RelatedEntityType = 'PURCHASE_ORDER'
                    AND EXISTS
                    (
                        SELECT 1
                        FROM dbo.PURCHASE_ORDERS po
                        WHERE po.POID = n.RelatedEntityID
                          AND
                          (
                              po.PRID = i.PRID
                              OR EXISTS
                              (
                                  SELECT 1
                                  FROM dbo.PO_PR_Mapping m
                                  WHERE m.POID = po.POID
                                    AND m.PRID = i.PRID
                              )
                          )
                    )
                )
                OR
                (
                    n.RelatedEntityType = 'REQUISITION'
                    AND EXISTS
                    (
                        SELECT 1
                        FROM dbo.PURCHASE_REQUESTS pr
                        INNER JOIN dbo.REPLENISHMENT_REQUESTS rr
                            ON rr.RepFID = pr.RepFID
                        WHERE pr.PRID = i.PRID
                          AND rr.OriginRequisitionID = n.RelatedEntityID
                    )
                )
            )
      );
END;
GO

/* ================================================================
   2. TRIGGER: REPLENISHMENT_REQUESTS - auto-mark sa shortage
      notifications kung na-receive na ang RepF (Status =
      'Processed', giset sa usp_Inventory_ReceiveStock).
   ================================================================ */
CREATE   TRIGGER trg_REPLENISHMENT_REQUESTS_AutoMarkNotifications
ON REPLENISHMENT_REQUESTS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RepFID = i.RepFID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RepFID = n.RelatedEntityID
    WHERE n.NotificationType = 'STOCK_SHORTAGE'
      AND n.RelatedEntityType = 'REPLENISHMENT_REQUEST'
      AND i.Status = 'Processed'
      AND n.IsRead = 0;
END;
GO

/* ============================================================
   5. DELIVERY READY NOTIFICATION â€” TARGET delivery.manage ONLY
   ============================================================ */

CREATE   TRIGGER dbo.trg_REQUISITION_DETAILS_AllocatedReadyNotify
ON dbo.REQUISITION_DETAILS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.NOTIFICATIONS (RecipientUserID, NotificationType, Title, Message, RelatedEntityType, RelatedEntityID, IsRead, CreatedAt)
    SELECT DISTINCT u.UserID, N'REQUISITION_ALLOCATED', N'Requisition ready for delivery',
           CONCAT(N'All items of requisition #', r.RequisitionID,
                  N' are allocated. Generate the acknowledgement receipt in the Delivery module.'),
           N'REQUISITION', r.RequisitionID, 0, SYSDATETIME()
    FROM inserted i
    INNER JOIN deleted d ON d.RequisitionDetailID = i.RequisitionDetailID
    INNER JOIN dbo.REQUISITIONS r ON r.RequisitionID = i.RequisitionID
    INNER JOIN dbo.USERS u
        ON u.IsActive = 1
       AND u.UserID <> r.RequestorUserID
       AND EXISTS (
            SELECT 1
            FROM dbo.ROLES ro
            INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = ro.RoleID
            INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
            WHERE ro.RoleID = u.RoleID
              AND ro.IsActive = 1
              AND p.PermissionCode = N'delivery.manage'
       )
    WHERE i.Status = N'Approved'
      AND d.Status <> N'Approved'
      AND r.Status = N'Approved'
      AND NOT EXISTS (
            SELECT 1 FROM dbo.REQUISITION_DETAILS x
            WHERE x.RequisitionID = r.RequisitionID
              AND x.Status IN (N'Pending', N'Partially Fulfilled')
      )
      AND NOT EXISTS (
            SELECT 1 FROM dbo.DELIVERIES y
            WHERE y.RequisitionID = r.RequisitionID
              AND y.Status IN (N'Generated', N'Issued')
      )
      AND NOT EXISTS (
            SELECT 1 FROM dbo.NOTIFICATIONS n
            WHERE n.RecipientUserID = u.UserID
              AND n.NotificationType = N'REQUISITION_ALLOCATED'
              AND n.RelatedEntityType = N'REQUISITION'
              AND n.RelatedEntityID = r.RequisitionID
              AND n.IsRead = 0
      );
END;
GO

/* ============================================================
   2. APPLY RECONCILIATION WHEN A REQUISITION IS CANCELLED
   ============================================================ */

CREATE   TRIGGER dbo.trg_Purchasing_RequisitionCancelled
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ID INT;

    DECLARE changed CURSOR LOCAL FAST_FORWARD FOR
        SELECT i.RequisitionID
        FROM inserted i
        INNER JOIN deleted d
            ON d.RequisitionID = i.RequisitionID
        WHERE i.Status = 'Cancelled'
          AND d.Status <> 'Cancelled';

    OPEN changed;

    FETCH NEXT FROM changed INTO @ID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Purchasing_ReconcileCancelledDemand
            @RequisitionID = @ID;

        FETCH NEXT FROM changed INTO @ID;
    END;

    CLOSE changed;
    DEALLOCATE changed;
END;
GO

/* ================================================================
   1. TRIGGER: REQUISITIONS - auto-mark sa review notifications
      kung ma-resolve na ang requisition (Approved/Rejected/
      Cancelled).
   ================================================================ */
CREATE   TRIGGER trg_REQUISITIONS_AutoMarkNotifications
ON REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Kani nga guard kay para mo-fire lang kung naay status change
    -- (dili mo-uban ang ubang column updates ug multi-row updates
    -- nga wala'y status transition).
    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status <> d.Status
    )
        RETURN;

    -- Kani nga mark kay para sa TANANG recipients (ang review action
    -- kay resolved na system-wide - wala na'y kinahanglan mo-review).
    -- Kani nga ReadAt kay required sa CK_NOTIFICATIONS_ReadState
    -- constraint (IsRead=1 => ReadAt NOT NULL).
    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType = 'REQUISITION_SUBMITTED'
      AND n.RelatedEntityType = 'REQUISITION'
      AND i.Status IN ('Approved', 'Rejected', 'Cancelled')
      AND n.IsRead = 0;
END;
GO

/* ============================================================
   7. REQUISITION FULFILLED / CANCELLED AUTO-MARK & CANCEL RECIPIENTS
   ============================================================ */

CREATE   TRIGGER dbo.trg_REQUISITIONS_FulfilledAutoMarkNotifications
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status <> d.Status
    )
        RETURN;

    UPDATE n
    SET IsRead = 1, ReadAt = SYSDATETIME()
    FROM dbo.NOTIFICATIONS n
    INNER JOIN inserted i ON i.RequisitionID = n.RelatedEntityID
    WHERE n.NotificationType IN (
        N'REQUISITION_APPROVED',
        N'STOCK_RESERVED',
        N'STOCK_ALLOCATED',
        N'STOCK_SHORTAGE',
        N'REQUISITION_ALLOCATED'
    )
      AND n.RelatedEntityType = N'REQUISITION'
      AND i.Status IN (N'Fulfilled', N'Cancelled')
      AND n.IsRead = 0;
END;
GO

/*
   2. ARCHIVE TRIGGER — kung ma-Fulfilled ang requisition (delivery
      completion), automatic nga ma-set ang ArchivedAt. Dili kini
      mo-touch sa ubang status.
*/
CREATE   TRIGGER dbo.trg_REQUISITIONS_SetArchivedAt
ON dbo.REQUISITIONS
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
        WHERE i.Status = N'Fulfilled'
          AND d.Status <> N'Fulfilled'
    )
        RETURN;

    UPDATE r
    SET ArchivedAt = SYSDATETIME()
    FROM dbo.REQUISITIONS r
    INNER JOIN inserted i ON i.RequisitionID = r.RequisitionID
    INNER JOIN deleted d ON d.RequisitionID = i.RequisitionID
    WHERE i.Status = N'Fulfilled'
      AND d.Status <> N'Fulfilled'
      AND r.ArchivedAt IS NULL;
END;
GO

-- 8. CLEAN STARTER SEED DATA
-- Seed dbo.ROLES (5 rows)
SET IDENTITY_INSERT [dbo].[ROLES] ON;
INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (1, N'Admin', N'Manages salon users, settings and overall operations.', 1);
INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (2, N'Manager', N'Supervises operations and handles requisition approvals.', 1);
INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (3, N'Inventory Staff', N'Manages inventory, receiving and releasing of items.', 1);
INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (4, N'Purchasing Staff', N'Handles purchase requests, quotations and purchase orders.', 1);
INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (5, N'Staff', N'Submits requisitions and acknowledges their own delivered items.', 1);
SET IDENTITY_INSERT [dbo].[ROLES] OFF;
GO

-- Seed dbo.PERMISSIONS (27 rows)
SET IDENTITY_INSERT [dbo].[PERMISSIONS] ON;
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (1, N'dashboard.view', N'View the dashboard');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (2, N'users.view', N'View user accounts');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (3, N'users.create', N'Create user accounts');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (4, N'users.update', N'Update user accounts');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (5, N'users.deactivate', N'Deactivate user accounts');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (6, N'users.assign_role', N'Assign allowed user roles');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (7, N'roles.view', N'View available roles');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (8, N'inventory.view', N'View inventory');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (9, N'inventory.create', N'Add inventory items');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (10, N'inventory.update', N'Update inventory items');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (11, N'inventory.adjust', N'Adjust inventory quantities');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (12, N'requisitions.view', N'View requisitions');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (13, N'requisitions.create', N'Create requisitions');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (14, N'requisitions.approve', N'Approve requisitions');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (15, N'requisitions.reject', N'Reject requisitions');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (16, N'purchasing.view', N'View purchasing records');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (17, N'purchasing.manage', N'Manage purchase requests and purchase orders');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (18, N'suppliers.view', N'View suppliers');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (19, N'suppliers.manage', N'Manage suppliers');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (20, N'receiving.view', N'View delivery and receiving records');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (21, N'receiving.manage', N'Record received deliveries');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (22, N'delivery.view', N'View delivery and acknowledgement records');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (23, N'delivery.manage', N'Issue items and manage acknowledgement receipts');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (24, N'reports.view', N'View system reports');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (25, N'settings.manage', N'Manage salon settings');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (26, N'reports.export', N'Print and export system reports');
INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (27, N'reports.audit', N'View sensitive audit and security reports');
SET IDENTITY_INSERT [dbo].[PERMISSIONS] OFF;
GO

-- Seed dbo.ROLE_PERMISSIONS (67 rows)
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 1);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 2);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 3);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 4);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 5);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 6);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 7);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 8);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 9);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 10);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 11);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 12);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 13);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 14);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 15);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 16);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 17);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 18);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 19);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 20);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 21);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 22);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 23);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 24);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 25);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 26);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (1, 27);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 1);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 2);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 7);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 8);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 12);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 13);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 14);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 15);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 16);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 18);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 20);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 22);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 24);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 26);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (2, 27);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 1);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 8);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 9);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 10);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 11);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 12);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 20);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 21);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 22);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 23);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 24);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (3, 26);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 1);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 8);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 16);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 17);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 18);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 19);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 24);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (4, 26);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (5, 1);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (5, 12);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (5, 13);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (5, 22);
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID]) VALUES (5, 24);
GO

-- Seed dbo.DOCUMENT_SIGNATURE_STAGES (15 rows)
SET IDENTITY_INSERT [dbo].[DOCUMENT_SIGNATURE_STAGES] ON;
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (1, N'CORRECTION_REPORT', N'Corrected', N'Corrected by', N'Corrected by', N'delivery.manage', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (2, N'PURCHASE_ORDER', N'Approved', N'Approved by', N'Approver', N'requisitions.approve', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (3, N'RECEIVING_REPORT', N'Received', N'Received by', N'Receiver', N'receiving.manage', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (4, N'REPLENISHMENT_REQUEST', N'Approved', N'Approved by', N'Approver', N'purchasing.manage,requisitions.approve', 20, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (5, N'REPLENISHMENT_REQUEST', N'Requested', N'Requested by', N'Requestor', N'inventory.update', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (6, N'REQUISITION', N'Approved', N'Approved by', N'Approver', N'requisitions.approve', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (7, N'STOCK_CARD', N'Custodian', N'Inventory custodian', N'Custodian', N'inventory.update,inventory.adjust,receiving.manage', 20, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (8, N'STOCK_CARD', N'Prepared', N'Prepared by', N'Prepared by', N'inventory.create,inventory.update', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (9, N'ACKNOWLEDGEMENT_RECEIPT', N'Issued', N'Issued by', N'Inventory Staff', N'delivery.manage', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (10, N'ACKNOWLEDGEMENT_RECEIPT', N'Received', N'Received by', N'Requestor', N'delivery.view', 20, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (11, N'RECEIVING_REPORT', N'Checked', N'Checked by', N'Checker', N'receiving.manage,purchasing.manage', 20, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (12, N'DELIVERY_CHECK', N'Checked', N'Checked by', N'Checker', N'purchasing.manage', 10, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (13, N'REQUISITION', N'Requested', N'Requested by', N'Requestor', N'requisitions.create', 5, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (14, N'REPLENISHMENT_REQUEST', N'Inventory', N'Inventory staff', N'Inventory Staff', N'inventory.update,receiving.manage', 15, 1);
INSERT INTO [dbo].[DOCUMENT_SIGNATURE_STAGES] ([StageID], [DocumentType], [Stage], [StageLabel], [RoleLabel], [PermissionCodes], [SortOrder], [IsActive]) VALUES (15, N'PURCHASE_ORDER', N'Requested', N'Requested by', N'Purchasing Staff', N'purchasing.manage', 5, 1);
SET IDENTITY_INSERT [dbo].[DOCUMENT_SIGNATURE_STAGES] OFF;
GO

-- Seed dbo.SYSTEM_SETTINGS (3 rows)
INSERT INTO [dbo].[SYSTEM_SETTINGS] ([SettingKey], [SettingValue], [UpdatedAt]) VALUES (N'DefaultRestockDays', N'7', '2026-11-15T18:01:58');
INSERT INTO [dbo].[SYSTEM_SETTINGS] ([SettingKey], [SettingValue], [UpdatedAt]) VALUES (N'SalonName', N'Just MakeOver', '2026-11-15T18:01:58');
INSERT INTO [dbo].[SYSTEM_SETTINGS] ([SettingKey], [SettingValue], [UpdatedAt]) VALUES (N'SalonTagline', N'Beauty Salon & Spa', '2026-11-15T18:01:58');
GO

-- Seed dbo.CATEGORIES (4 rows)
SET IDENTITY_INSERT [dbo].[CATEGORIES] ON;
INSERT INTO [dbo].[CATEGORIES] ([CategoryID], [CategoryName], [IsActive]) VALUES (1, N'Consumables', 1);
INSERT INTO [dbo].[CATEGORIES] ([CategoryID], [CategoryName], [IsActive]) VALUES (2, N'Hair Care Products', 1);
INSERT INTO [dbo].[CATEGORIES] ([CategoryID], [CategoryName], [IsActive]) VALUES (3, N'Skin Care Products', 1);
INSERT INTO [dbo].[CATEGORIES] ([CategoryID], [CategoryName], [IsActive]) VALUES (4, N'Tools & Equipment', 1);
SET IDENTITY_INSERT [dbo].[CATEGORIES] OFF;
GO

-- Seed dbo.UNIT_OF_MEASURES (5 rows)
SET IDENTITY_INSERT [dbo].[UNIT_OF_MEASURES] ON;
INSERT INTO [dbo].[UNIT_OF_MEASURES] ([UomID], [UomName], [IsActive], [CreatedAt]) VALUES (1, N'bottle', 1, '2026-11-15T17:56:00');
INSERT INTO [dbo].[UNIT_OF_MEASURES] ([UomID], [UomName], [IsActive], [CreatedAt]) VALUES (2, N'pair', 1, '2026-11-15T17:56:00');
INSERT INTO [dbo].[UNIT_OF_MEASURES] ([UomID], [UomName], [IsActive], [CreatedAt]) VALUES (3, N'piece', 1, '2026-11-15T17:56:00');
INSERT INTO [dbo].[UNIT_OF_MEASURES] ([UomID], [UomName], [IsActive], [CreatedAt]) VALUES (4, N'tube', 1, '2026-11-15T17:56:00');
INSERT INTO [dbo].[UNIT_OF_MEASURES] ([UomID], [UomName], [IsActive], [CreatedAt]) VALUES (5, N'unit', 1, '2026-11-15T17:56:00');
SET IDENTITY_INSERT [dbo].[UNIT_OF_MEASURES] OFF;
GO

-- Seed dbo.USERS (1 rows)
SET IDENTITY_INSERT [dbo].[USERS] ON;
INSERT INTO [dbo].[USERS] ([UserID], [LastName], [FirstName], [MiddleName], [Username], [PasswordHash], [Email], [RoleID], [IsActive], [FailedLoginAttempts], [LockoutEnd], [MustChangePassword], [PasswordChangedAt], [DateCreated], [LastLogin]) VALUES (1, N'Salon', N'Administrator', NULL, N'admin', N'PBKDF2-SHA256:100000:Z1JZjXq1BmqAW5uBuM3OyKLTqTgoP5lO5p4FmrN9KxQ=:vI5R1v//4OCz0Nvb2ijoyElsgLWjZgC8GMtrrrfIG1F+Zv08+sK8sRpVCt/cppAz+3MJqHOnHCQNdM9gNCKg2w==', N'admin@justmakeover.local', 1, 1, 0, NULL, 0, '2026-11-10T12:25:33', '2026-11-10T11:42:04', NULL);
SET IDENTITY_INSERT [dbo].[USERS] OFF;
GO

