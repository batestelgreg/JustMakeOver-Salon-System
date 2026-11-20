/*
   V000 - Base schema ug baseline RBAC seed

   Kini nga migration kay naghimo sa 26 ka base tables nga
   gituohan na daan sa V001-V019 (USERS, ROLES, ITEMS,
   INVENTORY, REQUISITIONS, PURCHASE_ORDERS, NOTIFICATIONS,
   ug uban pa). Sa wala pa kini, ang repo dili makabuild og
   fresh database kay puro procedures/seed ra ang migrations.

   Ang 7 ka tables nga gahimo sa ubang migrations (UNIT_OF_MEASURES,
   SYSTEM_SETTINGS, DELIVERIES, DELIVERY_ITEMS,
   PURCHASING_PO_TRACKING, PURCHASING_FOLLOWUPS,
   PURCHASING_DR_TRACKING) kay naa sa V006/V010/V012 - dili diri,
   para isa ra ka tag-iya ang matag table.

   Kini idempotent: guarded CREATE TABLE, guarded PK/UQ/CHECK/INDEX/FK,
   ug seed nga naay NOT EXISTS. Pwede i-rerun bisan pila ka beses.

   Seed ra dinhi: 25 permissions, 5 roles, role-permission matrix,
   ug ang admin account (UserID 1, must change password sa first login).
   Ang demo users ug sample items kay wala giapil kay test data na.
*/

USE JustMakeOverSalonDB;
GO

/* Kini nga SET options kay gikinahanglan sa persisted computed column
   (INVENTORY.QuantityAvailable) ug para consistent ang query plans. */
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET ARITHABORT ON;
GO

/* ============================================================
   1. BASE TABLES
   ============================================================ */

IF OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]', N'U') IS NULL
    CREATE TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]
    (
        [ARDetailID] INT IDENTITY(1,1) NOT NULL,
        [ARID] INT NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityIssued] INT NOT NULL
    );
GO

IF OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]', N'U') IS NULL
    CREATE TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS]
    (
        [ARID] INT IDENTITY(1,1) NOT NULL,
        [RequisitionID] INT NOT NULL,
        [IssuedByUserID] INT NOT NULL,
        [ReceivedByUserID] INT NOT NULL,
        [IssueDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_AR_IssueDate] DEFAULT (sysdatetime()),
        [ESignatureData] NVARCHAR(MAX) NOT NULL,
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_AR_Status] DEFAULT ('Fulfilled')
    );
GO

IF OBJECT_ID(N'[dbo].[CATEGORIES]', N'U') IS NULL
    CREATE TABLE [dbo].[CATEGORIES]
    (
        [CategoryID] INT IDENTITY(1,1) NOT NULL,
        [CategoryName] NVARCHAR(50) NOT NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF__CATEGORIE__IsAct__52E34C9D] DEFAULT ((1))
    );
GO

IF OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]', N'U') IS NULL
    CREATE TABLE [dbo].[DELIVERY_RECEIPT_DETAILS]
    (
        [DRDetailID] INT IDENTITY(1,1) NOT NULL,
        [DRID] INT NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityDelivered] INT NOT NULL,
        [QuantityAccepted] INT NOT NULL CONSTRAINT [DF_DRDETAILS_Accepted] DEFAULT ((0)),
        [QuantityRejected] INT NOT NULL CONSTRAINT [DF_DRDETAILS_Rejected] DEFAULT ((0)),
        [Remarks] NVARCHAR(500) NULL
    );
GO

IF OBJECT_ID(N'[dbo].[DELIVERY_RECEIPTS]', N'U') IS NULL
    CREATE TABLE [dbo].[DELIVERY_RECEIPTS]
    (
        [DRID] INT IDENTITY(1,1) NOT NULL,
        [POID] INT NOT NULL,
        [DeliveryDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_DR_DeliveryDate] DEFAULT (sysdatetime()),
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_DR_Status] DEFAULT ('Accepted'),
        [Notes] NVARCHAR(MAX) NULL
    );
GO

IF OBJECT_ID(N'[dbo].[INVENTORY]', N'U') IS NULL
    CREATE TABLE [dbo].[INVENTORY]
    (
        [InventoryID] INT IDENTITY(1,1) NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityOnHand] INT NOT NULL CONSTRAINT [DF_INVENTORY_QuantityOnHand] DEFAULT ((0)),
        [QuantityReserved] INT NOT NULL CONSTRAINT [DF_INVENTORY_QuantityReserved] DEFAULT ((0)),
        [QuantityAvailable] AS ([QuantityOnHand]-[QuantityReserved]) PERSISTED,
        [LastUpdated] DATETIME2(0) NOT NULL CONSTRAINT [DF_INVENTORY_LastUpdated] DEFAULT (sysdatetime())
    );
GO

IF OBJECT_ID(N'[dbo].[INVENTORY_LOGS]', N'U') IS NULL
    CREATE TABLE [dbo].[INVENTORY_LOGS]
    (
        [InventoryLogID] BIGINT IDENTITY(1,1) NOT NULL,
        [ItemID] INT NOT NULL,
        [UserID] INT NOT NULL,
        [TransactionType] VARCHAR(30) NOT NULL,
        [QuantityChange] INT NOT NULL,
        [PreviousQuantity] INT NOT NULL,
        [NewQuantity] INT NOT NULL,
        [ReferenceType] VARCHAR(30) NULL,
        [ReferenceID] INT NULL,
        [Remarks] NVARCHAR(500) NULL,
        [TransactionDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_INVENTORY_LOGS_Date] DEFAULT (sysdatetime())
    );
GO

IF OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[INVENTORY_RESERVATIONS]
    (
        [ReservationID] INT IDENTITY(1,1) NOT NULL,
        [RequisitionDetailID] INT NOT NULL,
        [QuantityReserved] INT NOT NULL,
        [ReservationDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_RESERVATIONS_Date] DEFAULT (sysdatetime()),
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_RESERVATIONS_Status] DEFAULT ('Active')
    );
GO

IF OBJECT_ID(N'[dbo].[ITEMS]', N'U') IS NULL
    CREATE TABLE [dbo].[ITEMS]
    (
        [ItemID] INT IDENTITY(1,1) NOT NULL,
        [ItemCode] VARCHAR(30) NOT NULL,
        [ItemName] NVARCHAR(100) NOT NULL,
        [CategoryID] INT NOT NULL,
        [UnitOfMeasure] NVARCHAR(20) NOT NULL,
        [ReorderPoint] INT NOT NULL CONSTRAINT [DF_ITEMS_ReorderPoint] DEFAULT ((10)),
        [UnitPrice] DECIMAL(10,2) NOT NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF_ITEMS_IsActive] DEFAULT ((1))
    );
GO

IF OBJECT_ID(N'[dbo].[NOTIFICATIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[NOTIFICATIONS]
    (
        [NotificationID] BIGINT IDENTITY(1,1) NOT NULL,
        [RecipientUserID] INT NOT NULL,
        [NotificationType] VARCHAR(50) NOT NULL,
        [Title] NVARCHAR(150) NOT NULL,
        [Message] NVARCHAR(1000) NOT NULL,
        [RelatedEntityType] VARCHAR(50) NULL,
        [RelatedEntityID] INT NULL,
        [IsRead] BIT NOT NULL CONSTRAINT [DF_NOTIFICATIONS_IsRead] DEFAULT ((0)),
        [CreatedAt] DATETIME2(0) NOT NULL CONSTRAINT [DF_NOTIFICATIONS_CreatedAt] DEFAULT (sysdatetime()),
        [ReadAt] DATETIME2(0) NULL
    );
GO

IF OBJECT_ID(N'[dbo].[PERMISSIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[PERMISSIONS]
    (
        [PermissionID] INT IDENTITY(1,1) NOT NULL,
        [PermissionCode] VARCHAR(100) NOT NULL,
        [Description] NVARCHAR(255) NULL
    );
GO

IF OBJECT_ID(N'[dbo].[PO_PR_Mapping]', N'U') IS NULL
    CREATE TABLE [dbo].[PO_PR_Mapping]
    (
        [POID] INT NOT NULL,
        [PRID] INT NOT NULL
    );
GO

IF OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]', N'U') IS NULL
    CREATE TABLE [dbo].[PURCHASE_BUDGETS]
    (
        [BudgetID] INT IDENTITY(1,1) NOT NULL,
        [BudgetYear] INT NOT NULL,
        [BudgetAmount] DECIMAL(14,2) NOT NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF_PURCHASE_BUDGETS_IsActive] DEFAULT ((1)),
        [CreatedByUserID] INT NOT NULL,
        [CreatedAt] DATETIME2(0) NOT NULL CONSTRAINT [DF_PURCHASE_BUDGETS_CreatedAt] DEFAULT (sysdatetime()),
        [UpdatedAt] DATETIME2(0) NULL
    );
GO

IF OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]', N'U') IS NULL
    CREATE TABLE [dbo].[PURCHASE_ORDERS]
    (
        [POID] INT IDENTITY(1,1) NOT NULL,
        [PRID] INT NOT NULL,
        [SupplierID] INT NOT NULL,
        [ApprovedByUserID] INT NULL,
        [QuantityOrdered] INT NOT NULL,
        [UnitPrice] DECIMAL(10,2) NOT NULL,
        [TotalAmount] DECIMAL(12,2) NOT NULL,
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_PO_Status] DEFAULT ('Pending Approval'),
        [DateIssued] DATETIME2(0) NOT NULL CONSTRAINT [DF_PO_DateIssued] DEFAULT (sysdatetime())
    );
GO

IF OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]', N'U') IS NULL
    CREATE TABLE [dbo].[PURCHASE_REQUESTS]
    (
        [PRID] INT IDENTITY(1,1) NOT NULL,
        [RepFID] INT NOT NULL,
        [CreatedByUserID] INT NOT NULL,
        [DateCreated] DATETIME2(0) NOT NULL CONSTRAINT [DF_PURCHASE_REQUESTS_DateCreated] DEFAULT (sysdatetime()),
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_PURCHASE_REQUESTS_Status] DEFAULT ('Open')
    );
GO

IF OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]', N'U') IS NULL
    CREATE TABLE [dbo].[RECEIVING_MEMO_DETAILS]
    (
        [RMDetailID] INT IDENTITY(1,1) NOT NULL,
        [RMID] INT NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityReceived] INT NOT NULL
    );
GO

IF OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]', N'U') IS NULL
    CREATE TABLE [dbo].[RECEIVING_MEMOS]
    (
        [RMID] INT IDENTITY(1,1) NOT NULL,
        [DRID] INT NOT NULL,
        [ReceivedByUserID] INT NOT NULL,
        [DateReceived] DATETIME2(0) NOT NULL CONSTRAINT [DF_RM_DateReceived] DEFAULT (sysdatetime()),
        [Remarks] NVARCHAR(MAX) NULL,
        [InventoryUpdated] BIT NOT NULL CONSTRAINT [DF_RM_InventoryUpdated] DEFAULT ((0))
    );
GO

IF OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]', N'U') IS NULL
    CREATE TABLE [dbo].[REPLENISHMENT_REQUESTS]
    (
        [RepFID] INT IDENTITY(1,1) NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityNeeded] INT NOT NULL,
        [DateGenerated] DATETIME2(0) NOT NULL CONSTRAINT [DF_REPF_DateGenerated] DEFAULT (sysdatetime()),
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_REPF_Status] DEFAULT ('Pending'),
        [QuantityReceived] INT NOT NULL CONSTRAINT [DF_REPF_QuantityReceived] DEFAULT ((0)),
        [OriginRequisitionID] INT NULL
    );
GO

IF OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]', N'U') IS NULL
    CREATE TABLE [dbo].[REQUISITION_DETAILS]
    (
        [RequisitionDetailID] INT IDENTITY(1,1) NOT NULL,
        [RequisitionID] INT NOT NULL,
        [ItemID] INT NOT NULL,
        [QuantityRequested] INT NOT NULL,
        [QuantityApproved] INT NULL,
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_REQDETAILS_Status] DEFAULT ('Pending')
    );
GO

IF OBJECT_ID(N'[dbo].[REQUISITIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[REQUISITIONS]
    (
        [RequisitionID] INT IDENTITY(1,1) NOT NULL,
        [RequestorUserID] INT NOT NULL,
        [DepartmentHeadUserID] INT NULL,
        [RequestDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_REQUISITIONS_RequestDate] DEFAULT (sysdatetime()),
        [RequiredDate] DATE NOT NULL,
        [Justification] NVARCHAR(500) NULL,
        [Status] VARCHAR(30) NOT NULL CONSTRAINT [DF_REQUISITIONS_Status] DEFAULT ('Pending'),
        [RejectionReason] NVARCHAR(500) NULL,
        [ArchivedAt] DATETIME NULL
    );
GO

IF OBJECT_ID(N'[dbo].[ROLE_PERMISSIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[ROLE_PERMISSIONS]
    (
        [RoleID] INT NOT NULL,
        [PermissionID] INT NOT NULL
    );
GO

IF OBJECT_ID(N'[dbo].[ROLES]', N'U') IS NULL
    CREATE TABLE [dbo].[ROLES]
    (
        [RoleID] INT IDENTITY(1,1) NOT NULL,
        [RoleName] NVARCHAR(50) NOT NULL,
        [Description] NVARCHAR(255) NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF_ROLES_IsActive] DEFAULT ((1))
    );
GO

IF OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]', N'U') IS NULL
    CREATE TABLE [dbo].[SUPPLIER_QUOTATIONS]
    (
        [QuotationID] INT IDENTITY(1,1) NOT NULL,
        [PRID] INT NOT NULL,
        [SupplierID] INT NOT NULL,
        [QuotedPrice] DECIMAL(10,2) NOT NULL,
        [IsRecommended] BIT NOT NULL CONSTRAINT [DF_QUOTATIONS_IsRecommended] DEFAULT ((0)),
        [DateQuoted] DATETIME2(0) NOT NULL CONSTRAINT [DF_QUOTATIONS_DateQuoted] DEFAULT (sysdatetime())
    );
GO

IF OBJECT_ID(N'[dbo].[SUPPLIERS]', N'U') IS NULL
    CREATE TABLE [dbo].[SUPPLIERS]
    (
        [SupplierID] INT IDENTITY(1,1) NOT NULL,
        [SupplierCode] VARCHAR(30) NOT NULL,
        [SupplierName] NVARCHAR(100) NOT NULL,
        [ContactPersonLastName] NVARCHAR(50) NOT NULL,
        [ContactPersonFirstName] NVARCHAR(50) NOT NULL,
        [ContactPersonMiddleName] NVARCHAR(50) NULL,
        [Phone] VARCHAR(20) NOT NULL,
        [Email] NVARCHAR(254) NULL,
        [Address] NVARCHAR(1000) NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF_SUPPLIERS_IsActive] DEFAULT ((1))
    );
GO

IF OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]', N'U') IS NULL
    CREATE TABLE [dbo].[USER_AUDIT_LOGS]
    (
        [AuditID] BIGINT IDENTITY(1,1) NOT NULL,
        [ActorUserID] INT NULL,
        [TargetUserID] INT NULL,
        [ActionType] VARCHAR(50) NOT NULL,
        [Description] NVARCHAR(500) NULL,
        [IPAddress] VARCHAR(45) NULL,
        [ActionDate] DATETIME2(0) NOT NULL CONSTRAINT [DF_USER_AUDIT_LOGS_ActionDate] DEFAULT (sysdatetime())
    );
GO

IF OBJECT_ID(N'[dbo].[USERS]', N'U') IS NULL
    CREATE TABLE [dbo].[USERS]
    (
        [UserID] INT IDENTITY(1,1) NOT NULL,
        [LastName] NVARCHAR(50) NOT NULL,
        [FirstName] NVARCHAR(50) NOT NULL,
        [MiddleName] NVARCHAR(50) NULL,
        [Username] NVARCHAR(50) NOT NULL,
        [PasswordHash] VARCHAR(255) NOT NULL,
        [Email] NVARCHAR(254) NOT NULL,
        [RoleID] INT NOT NULL,
        [IsActive] BIT NOT NULL CONSTRAINT [DF_USERS_IsActive] DEFAULT ((1)),
        [FailedLoginAttempts] INT NOT NULL CONSTRAINT [DF_USERS_FailedLoginAttempts] DEFAULT ((0)),
        [LockoutEnd] DATETIME2(0) NULL,
        [MustChangePassword] BIT NOT NULL CONSTRAINT [DF_USERS_MustChangePassword] DEFAULT ((1)),
        [PasswordChangedAt] DATETIME2(0) NULL,
        [DateCreated] DATETIME2(0) NOT NULL CONSTRAINT [DF_USERS_DateCreated] DEFAULT (sysdatetime()),
        [LastLogin] DATETIME2(0) NULL
    );
GO

/* ============================================================
   2. PRIMARY KEYS ug UNIQUE CONSTRAINTS
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_AR_DETAILS' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] ADD CONSTRAINT [PK_AR_DETAILS] PRIMARY KEY CLUSTERED ([ARDetailID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_ARDETAILS_AR_Item' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] ADD CONSTRAINT [UQ_ARDETAILS_AR_Item] UNIQUE NONCLUSTERED ([ARID] ASC, [ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_ACKNOWLEDGEMENT_RECEIPTS' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ADD CONSTRAINT [PK_ACKNOWLEDGEMENT_RECEIPTS] PRIMARY KEY CLUSTERED ([ARID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_CATEGORIES' AND parent_object_id = OBJECT_ID(N'[dbo].[CATEGORIES]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[CATEGORIES]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[CATEGORIES] ADD CONSTRAINT [PK_CATEGORIES] PRIMARY KEY CLUSTERED ([CategoryID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_CATEGORIES_CategoryName' AND parent_object_id = OBJECT_ID(N'[dbo].[CATEGORIES]'))
    ALTER TABLE [dbo].[CATEGORIES] ADD CONSTRAINT [UQ_CATEGORIES_CategoryName] UNIQUE NONCLUSTERED ([CategoryName] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_DELIVERY_RECEIPT_DETAILS' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] ADD CONSTRAINT [PK_DELIVERY_RECEIPT_DETAILS] PRIMARY KEY CLUSTERED ([DRDetailID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_DRDETAILS_DR_Item' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] ADD CONSTRAINT [UQ_DRDETAILS_DR_Item] UNIQUE NONCLUSTERED ([DRID] ASC, [ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_DELIVERY_RECEIPTS' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPTS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPTS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[DELIVERY_RECEIPTS] ADD CONSTRAINT [PK_DELIVERY_RECEIPTS] PRIMARY KEY CLUSTERED ([DRID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_INVENTORY' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[INVENTORY]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[INVENTORY] ADD CONSTRAINT [PK_INVENTORY] PRIMARY KEY CLUSTERED ([InventoryID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_INVENTORY_ItemID' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY]'))
    ALTER TABLE [dbo].[INVENTORY] ADD CONSTRAINT [UQ_INVENTORY_ItemID] UNIQUE NONCLUSTERED ([ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_INVENTORY_LOGS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [PK_INVENTORY_LOGS] PRIMARY KEY CLUSTERED ([InventoryLogID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_INVENTORY_RESERVATIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[INVENTORY_RESERVATIONS] ADD CONSTRAINT [PK_INVENTORY_RESERVATIONS] PRIMARY KEY CLUSTERED ([ReservationID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[ITEMS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[ITEMS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[ITEMS] ADD CONSTRAINT [PK_ITEMS] PRIMARY KEY CLUSTERED ([ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_ITEMS_ItemCode' AND parent_object_id = OBJECT_ID(N'[dbo].[ITEMS]'))
    ALTER TABLE [dbo].[ITEMS] ADD CONSTRAINT [UQ_ITEMS_ItemCode] UNIQUE NONCLUSTERED ([ItemCode] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_NOTIFICATIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[NOTIFICATIONS] ADD CONSTRAINT [PK_NOTIFICATIONS] PRIMARY KEY CLUSTERED ([NotificationID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_PERMISSIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[PERMISSIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[PERMISSIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[PERMISSIONS] ADD CONSTRAINT [PK_PERMISSIONS] PRIMARY KEY CLUSTERED ([PermissionID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_PERMISSIONS_Code' AND parent_object_id = OBJECT_ID(N'[dbo].[PERMISSIONS]'))
    ALTER TABLE [dbo].[PERMISSIONS] ADD CONSTRAINT [UQ_PERMISSIONS_Code] UNIQUE NONCLUSTERED ([PermissionCode] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_PO_PR_Mapping' AND parent_object_id = OBJECT_ID(N'[dbo].[PO_PR_Mapping]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[PO_PR_Mapping]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[PO_PR_Mapping] ADD CONSTRAINT [PK_PO_PR_Mapping] PRIMARY KEY CLUSTERED ([POID] ASC, [PRID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_PURCHASE_BUDGETS' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[PURCHASE_BUDGETS] ADD CONSTRAINT [PK_PURCHASE_BUDGETS] PRIMARY KEY CLUSTERED ([BudgetID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_PURCHASE_BUDGETS_Year' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
    ALTER TABLE [dbo].[PURCHASE_BUDGETS] ADD CONSTRAINT [UQ_PURCHASE_BUDGETS_Year] UNIQUE NONCLUSTERED ([BudgetYear] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_PURCHASE_ORDERS' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [PK_PURCHASE_ORDERS] PRIMARY KEY CLUSTERED ([POID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_PURCHASE_REQUESTS' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[PURCHASE_REQUESTS] ADD CONSTRAINT [PK_PURCHASE_REQUESTS] PRIMARY KEY CLUSTERED ([PRID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_PURCHASE_REQUESTS_RepFID' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
    ALTER TABLE [dbo].[PURCHASE_REQUESTS] ADD CONSTRAINT [UQ_PURCHASE_REQUESTS_RepFID] UNIQUE NONCLUSTERED ([RepFID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_RECEIVING_MEMO_DETAILS' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] ADD CONSTRAINT [PK_RECEIVING_MEMO_DETAILS] PRIMARY KEY CLUSTERED ([RMDetailID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_RMDETAILS_RM_Item' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] ADD CONSTRAINT [UQ_RMDETAILS_RM_Item] UNIQUE NONCLUSTERED ([RMID] ASC, [ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_RECEIVING_MEMOS' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[RECEIVING_MEMOS] ADD CONSTRAINT [PK_RECEIVING_MEMOS] PRIMARY KEY CLUSTERED ([RMID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_RECEIVING_MEMOS_DRID' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMOS] ADD CONSTRAINT [UQ_RECEIVING_MEMOS_DRID] UNIQUE NONCLUSTERED ([DRID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_REPLENISHMENT_REQUESTS' AND parent_object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] ADD CONSTRAINT [PK_REPLENISHMENT_REQUESTS] PRIMARY KEY CLUSTERED ([RepFID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_REQUISITION_DETAILS' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[REQUISITION_DETAILS] ADD CONSTRAINT [PK_REQUISITION_DETAILS] PRIMARY KEY CLUSTERED ([RequisitionDetailID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_REQUISITIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[REQUISITIONS] ADD CONSTRAINT [PK_REQUISITIONS] PRIMARY KEY CLUSTERED ([RequisitionID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_ROLE_PERMISSIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[ROLE_PERMISSIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[ROLE_PERMISSIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[ROLE_PERMISSIONS] ADD CONSTRAINT [PK_ROLE_PERMISSIONS] PRIMARY KEY CLUSTERED ([RoleID] ASC, [PermissionID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_ROLES' AND parent_object_id = OBJECT_ID(N'[dbo].[ROLES]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[ROLES]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[ROLES] ADD CONSTRAINT [PK_ROLES] PRIMARY KEY CLUSTERED ([RoleID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_ROLES_RoleName' AND parent_object_id = OBJECT_ID(N'[dbo].[ROLES]'))
    ALTER TABLE [dbo].[ROLES] ADD CONSTRAINT [UQ_ROLES_RoleName] UNIQUE NONCLUSTERED ([RoleName] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_SUPPLIER_QUOTATIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] ADD CONSTRAINT [PK_SUPPLIER_QUOTATIONS] PRIMARY KEY CLUSTERED ([QuotationID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_QUOTATIONS_PR_Supplier' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
    ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] ADD CONSTRAINT [UQ_QUOTATIONS_PR_Supplier] UNIQUE NONCLUSTERED ([PRID] ASC, [SupplierID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_SUPPLIERS' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIERS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[SUPPLIERS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[SUPPLIERS] ADD CONSTRAINT [PK_SUPPLIERS] PRIMARY KEY CLUSTERED ([SupplierID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_SUPPLIERS_Code' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIERS]'))
    ALTER TABLE [dbo].[SUPPLIERS] ADD CONSTRAINT [UQ_SUPPLIERS_Code] UNIQUE NONCLUSTERED ([SupplierCode] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_USER_AUDIT_LOGS' AND parent_object_id = OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[USER_AUDIT_LOGS] ADD CONSTRAINT [PK_USER_AUDIT_LOGS] PRIMARY KEY CLUSTERED ([AuditID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'PK_USERS' AND parent_object_id = OBJECT_ID(N'[dbo].[USERS]'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[USERS]') AND is_primary_key = 1)
    ALTER TABLE [dbo].[USERS] ADD CONSTRAINT [PK_USERS] PRIMARY KEY CLUSTERED ([UserID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_USERS_Email' AND parent_object_id = OBJECT_ID(N'[dbo].[USERS]'))
    ALTER TABLE [dbo].[USERS] ADD CONSTRAINT [UQ_USERS_Email] UNIQUE NONCLUSTERED ([Email] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [name] = N'UQ_USERS_Username' AND parent_object_id = OBJECT_ID(N'[dbo].[USERS]'))
    ALTER TABLE [dbo].[USERS] ADD CONSTRAINT [UQ_USERS_Username] UNIQUE NONCLUSTERED ([Username] ASC);
GO

/* ============================================================
   3. CHECK CONSTRAINTS
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_ARDETAILS_Quantity' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] ADD CONSTRAINT [CK_ARDETAILS_Quantity] CHECK ([QuantityIssued]>(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_AR_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ADD CONSTRAINT [CK_AR_Status] CHECK ([Status]='Cancelled' OR [Status]='With Discrepancies' OR [Status]='Fulfilled' OR [Status]='Pending');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_DRDETAILS_Quantities' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] ADD CONSTRAINT [CK_DRDETAILS_Quantities] CHECK ([QuantityDelivered]>(0) AND [QuantityAccepted]>=(0) AND [QuantityRejected]>=(0) AND ([QuantityAccepted]+[QuantityRejected])<=[QuantityDelivered]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_DR_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPTS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPTS] ADD CONSTRAINT [CK_DR_Status] CHECK ([Status]='Rejected' OR [Status]='With Discrepancies' OR [Status]='Accepted');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_INVENTORY_Quantities' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY]'))
    ALTER TABLE [dbo].[INVENTORY] ADD CONSTRAINT [CK_INVENTORY_Quantities] CHECK ([QuantityOnHand]>=(0) AND [QuantityReserved]>=(0) AND [QuantityReserved]<=[QuantityOnHand]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_INVENTORY_LOGS_Quantities' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [CK_INVENTORY_LOGS_Quantities] CHECK ([PreviousQuantity]>=(0) AND [NewQuantity]>=(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_INVENTORY_LOGS_QuantityCalculation' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [CK_INVENTORY_LOGS_QuantityCalculation] CHECK ([NewQuantity]=([PreviousQuantity]+[QuantityChange]));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_INVENTORY_LOGS_Type' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [CK_INVENTORY_LOGS_Type] CHECK ([TransactionType]='Adjustment' OR [TransactionType]='Release' OR [TransactionType]='Reservation' OR [TransactionType]='Stock Out' OR [TransactionType]='Stock In');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_RESERVATIONS_Quantity' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
    ALTER TABLE [dbo].[INVENTORY_RESERVATIONS] ADD CONSTRAINT [CK_RESERVATIONS_Quantity] CHECK ([QuantityReserved]>(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_RESERVATIONS_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
    ALTER TABLE [dbo].[INVENTORY_RESERVATIONS] ADD CONSTRAINT [CK_RESERVATIONS_Status] CHECK ([Status]='Released' OR [Status]='Cancelled' OR [Status]='Fulfilled' OR [Status]='Active');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_ITEMS_ReorderPoint' AND parent_object_id = OBJECT_ID(N'[dbo].[ITEMS]'))
    ALTER TABLE [dbo].[ITEMS] ADD CONSTRAINT [CK_ITEMS_ReorderPoint] CHECK ([ReorderPoint]>=(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_ITEMS_UnitPrice' AND parent_object_id = OBJECT_ID(N'[dbo].[ITEMS]'))
    ALTER TABLE [dbo].[ITEMS] ADD CONSTRAINT [CK_ITEMS_UnitPrice] CHECK ([UnitPrice]>=(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_NOTIFICATIONS_ReadState' AND parent_object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]'))
    ALTER TABLE [dbo].[NOTIFICATIONS] ADD CONSTRAINT [CK_NOTIFICATIONS_ReadState] CHECK ([IsRead]=(0) AND [ReadAt] IS NULL OR [IsRead]=(1) AND [ReadAt] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_PURCHASE_BUDGETS_Amount' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
    ALTER TABLE [dbo].[PURCHASE_BUDGETS] ADD CONSTRAINT [CK_PURCHASE_BUDGETS_Amount] CHECK ([BudgetAmount]>=(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_PURCHASE_BUDGETS_Year' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
    ALTER TABLE [dbo].[PURCHASE_BUDGETS] ADD CONSTRAINT [CK_PURCHASE_BUDGETS_Year] CHECK ([BudgetYear]>=(2000) AND [BudgetYear]<=(2100));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_PO_QuantitiesAndPrices' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [CK_PO_QuantitiesAndPrices] CHECK ([QuantityOrdered]>(0) AND [UnitPrice]>=(0) AND [TotalAmount]>=(0) AND [TotalAmount]=[QuantityOrdered]*[UnitPrice]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_PO_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [CK_PO_Status] CHECK ([Status]='Cancelled' OR [Status]='Delivered' OR [Status]='Partially Delivered' OR [Status]='Sent to Supplier' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending Approval');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_PURCHASE_REQUESTS_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
    ALTER TABLE [dbo].[PURCHASE_REQUESTS] ADD CONSTRAINT [CK_PURCHASE_REQUESTS_Status] CHECK ([Status]='Closed' OR [Status]='Cancelled' OR [Status]='Processed' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending Approval' OR [Status]='Open');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_RMDETAILS_Quantity' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] ADD CONSTRAINT [CK_RMDETAILS_Quantity] CHECK ([QuantityReceived]>(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REPF_Quantity' AND parent_object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
    ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] ADD CONSTRAINT [CK_REPF_Quantity] CHECK ([QuantityNeeded]>(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REPF_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
    ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] ADD CONSTRAINT [CK_REPF_Status] CHECK ([Status]='Cancelled' OR [Status]='Processed' OR [Status]='Pending');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REQDETAILS_Quantities' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
    ALTER TABLE [dbo].[REQUISITION_DETAILS] ADD CONSTRAINT [CK_REQDETAILS_Quantities] CHECK ([QuantityRequested]>(0) AND ([QuantityApproved] IS NULL OR [QuantityApproved]>=(0) AND [QuantityApproved]<=[QuantityRequested]));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REQDETAILS_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
    ALTER TABLE [dbo].[REQUISITION_DETAILS] ADD CONSTRAINT [CK_REQDETAILS_Status] CHECK ([Status]='Fulfilled' OR [Status]='Partially Fulfilled' OR [Status]='Cancelled' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REQUISITIONS_RequiredDate' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    ALTER TABLE [dbo].[REQUISITIONS] ADD CONSTRAINT [CK_REQUISITIONS_RequiredDate] CHECK ([RequiredDate]>=CONVERT([date],[RequestDate]));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_REQUISITIONS_Status' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    ALTER TABLE [dbo].[REQUISITIONS] ADD CONSTRAINT [CK_REQUISITIONS_Status] CHECK ([Status]='Fulfilled' OR [Status]='Cancelled' OR [Status]='Rejected' OR [Status]='Approved' OR [Status]='Pending');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_QUOTATIONS_Price' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
    ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] ADD CONSTRAINT [CK_QUOTATIONS_Price] CHECK ([QuotedPrice]>=(0));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE [name] = N'CK_USERS_FailedLoginAttempts' AND parent_object_id = OBJECT_ID(N'[dbo].[USERS]'))
    ALTER TABLE [dbo].[USERS] ADD CONSTRAINT [CK_USERS_FailedLoginAttempts] CHECK ([FailedLoginAttempts]>=(0));
GO

/* ============================================================
   4. NONCLUSTERED INDEXES (apil ang filtered unique indexes)
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_DRDETAILS_ItemID' AND object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
    CREATE NONCLUSTERED INDEX [IX_DRDETAILS_ItemID] ON [dbo].[DELIVERY_RECEIPT_DETAILS] ([ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_INVENTORY_LOGS_Date' AND object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    CREATE NONCLUSTERED INDEX [IX_INVENTORY_LOGS_Date] ON [dbo].[INVENTORY_LOGS] ([TransactionDate] DESC, [ItemID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_INVENTORY_LOGS_ItemID_TransactionDate' AND object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    CREATE NONCLUSTERED INDEX [IX_INVENTORY_LOGS_ItemID_TransactionDate] ON [dbo].[INVENTORY_LOGS] ([ItemID] ASC, [TransactionDate] DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_RESERVATIONS_Detail' AND object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
    CREATE NONCLUSTERED INDEX [IX_RESERVATIONS_Detail] ON [dbo].[INVENTORY_RESERVATIONS] ([RequisitionDetailID] ASC, [Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_RESERVATIONS_RequisitionDetailID_Status' AND object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
    CREATE NONCLUSTERED INDEX [IX_RESERVATIONS_RequisitionDetailID_Status] ON [dbo].[INVENTORY_RESERVATIONS] ([RequisitionDetailID] ASC, [Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_NOTIFICATIONS_Recipient' AND object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]'))
    CREATE NONCLUSTERED INDEX [IX_NOTIFICATIONS_Recipient] ON [dbo].[NOTIFICATIONS] ([RecipientUserID] ASC, [IsRead] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_NOTIFICATIONS_Recipient_Read_Created' AND object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]'))
    CREATE NONCLUSTERED INDEX [IX_NOTIFICATIONS_Recipient_Read_Created] ON [dbo].[NOTIFICATIONS] ([RecipientUserID] ASC, [IsRead] ASC, [CreatedAt] DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_PO_PR_Mapping_PRID' AND object_id = OBJECT_ID(N'[dbo].[PO_PR_Mapping]'))
    CREATE NONCLUSTERED INDEX [IX_PO_PR_Mapping_PRID] ON [dbo].[PO_PR_Mapping] ([PRID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_PURCHASE_BUDGETS_ActiveYear' AND object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
    CREATE NONCLUSTERED INDEX [IX_PURCHASE_BUDGETS_ActiveYear] ON [dbo].[PURCHASE_BUDGETS] ([BudgetYear] ASC, [IsActive] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_PO_Status' AND object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    CREATE NONCLUSTERED INDEX [IX_PO_Status] ON [dbo].[PURCHASE_ORDERS] ([Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_PURCHASE_REQUESTS_Status' AND object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
    CREATE NONCLUSTERED INDEX [IX_PURCHASE_REQUESTS_Status] ON [dbo].[PURCHASE_REQUESTS] ([Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_REPF_Item_Status' AND object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
    CREATE NONCLUSTERED INDEX [IX_REPF_Item_Status] ON [dbo].[REPLENISHMENT_REQUESTS] ([ItemID] ASC, [Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_REQUISITION_DETAILS_RequisitionID' AND object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
    CREATE NONCLUSTERED INDEX [IX_REQUISITION_DETAILS_RequisitionID] ON [dbo].[REQUISITION_DETAILS] ([RequisitionID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_REQUISITIONS_RequestorUserID' AND object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    CREATE NONCLUSTERED INDEX [IX_REQUISITIONS_RequestorUserID] ON [dbo].[REQUISITIONS] ([RequestorUserID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_REQUISITIONS_Status' AND object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    CREATE NONCLUSTERED INDEX [IX_REQUISITIONS_Status] ON [dbo].[REQUISITIONS] ([Status] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'UX_QUOTATIONS_OneRecommendedPerPR' AND object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
    CREATE UNIQUE NONCLUSTERED INDEX [UX_QUOTATIONS_OneRecommendedPerPR] ON [dbo].[SUPPLIER_QUOTATIONS] ([PRID] ASC) WHERE ([IsRecommended]=(1));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'UX_SUPPLIERS_Email' AND object_id = OBJECT_ID(N'[dbo].[SUPPLIERS]'))
    CREATE UNIQUE NONCLUSTERED INDEX [UX_SUPPLIERS_Email] ON [dbo].[SUPPLIERS] ([Email] ASC) WHERE ([Email] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_USER_AUDIT_LOGS_TargetUserID_ActionDate' AND object_id = OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]'))
    CREATE NONCLUSTERED INDEX [IX_USER_AUDIT_LOGS_TargetUserID_ActionDate] ON [dbo].[USER_AUDIT_LOGS] ([TargetUserID] ASC, [ActionDate] DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_USERS_RoleID' AND object_id = OBJECT_ID(N'[dbo].[USERS]'))
    CREATE NONCLUSTERED INDEX [IX_USERS_RoleID] ON [dbo].[USERS] ([RoleID] ASC);
GO

/* ============================================================
   5. FOREIGN KEYS (human sa tanang tables para walay ordering issue)
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_ARDETAILS_AR' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] ADD CONSTRAINT [FK_ARDETAILS_AR] FOREIGN KEY ([ARID]) REFERENCES [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ([ARID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_ARDETAILS_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPT_DETAILS] ADD CONSTRAINT [FK_ARDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_AR_Issuer' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ADD CONSTRAINT [FK_AR_Issuer] FOREIGN KEY ([IssuedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_AR_Receiver' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ADD CONSTRAINT [FK_AR_Receiver] FOREIGN KEY ([ReceivedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_AR_Requisition' AND parent_object_id = OBJECT_ID(N'[dbo].[ACKNOWLEDGEMENT_RECEIPTS]'))
    ALTER TABLE [dbo].[ACKNOWLEDGEMENT_RECEIPTS] ADD CONSTRAINT [FK_AR_Requisition] FOREIGN KEY ([RequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_DRDETAILS_DR' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] ADD CONSTRAINT [FK_DRDETAILS_DR] FOREIGN KEY ([DRID]) REFERENCES [dbo].[DELIVERY_RECEIPTS] ([DRID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_DRDETAILS_ITEM' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPT_DETAILS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPT_DETAILS] ADD CONSTRAINT [FK_DRDETAILS_ITEM] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_DR_PO' AND parent_object_id = OBJECT_ID(N'[dbo].[DELIVERY_RECEIPTS]'))
    ALTER TABLE [dbo].[DELIVERY_RECEIPTS] ADD CONSTRAINT [FK_DR_PO] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_INVENTORY_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY]'))
    ALTER TABLE [dbo].[INVENTORY] ADD CONSTRAINT [FK_INVENTORY_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_INVENTORY_LOGS_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [FK_INVENTORY_LOGS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_INVENTORY_LOGS_USERS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_LOGS]'))
    ALTER TABLE [dbo].[INVENTORY_LOGS] ADD CONSTRAINT [FK_INVENTORY_LOGS_USERS] FOREIGN KEY ([UserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_RESERVATIONS_REQDETAILS' AND parent_object_id = OBJECT_ID(N'[dbo].[INVENTORY_RESERVATIONS]'))
    ALTER TABLE [dbo].[INVENTORY_RESERVATIONS] ADD CONSTRAINT [FK_RESERVATIONS_REQDETAILS] FOREIGN KEY ([RequisitionDetailID]) REFERENCES [dbo].[REQUISITION_DETAILS] ([RequisitionDetailID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_ITEMS_CATEGORIES' AND parent_object_id = OBJECT_ID(N'[dbo].[ITEMS]'))
    ALTER TABLE [dbo].[ITEMS] ADD CONSTRAINT [FK_ITEMS_CATEGORIES] FOREIGN KEY ([CategoryID]) REFERENCES [dbo].[CATEGORIES] ([CategoryID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_NOTIFICATIONS_RECIPIENT' AND parent_object_id = OBJECT_ID(N'[dbo].[NOTIFICATIONS]'))
    ALTER TABLE [dbo].[NOTIFICATIONS] ADD CONSTRAINT [FK_NOTIFICATIONS_RECIPIENT] FOREIGN KEY ([RecipientUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PO_PR_Mapping_PO' AND parent_object_id = OBJECT_ID(N'[dbo].[PO_PR_Mapping]'))
    ALTER TABLE [dbo].[PO_PR_Mapping] ADD CONSTRAINT [FK_PO_PR_Mapping_PO] FOREIGN KEY ([POID]) REFERENCES [dbo].[PURCHASE_ORDERS] ([POID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PO_PR_Mapping_PR' AND parent_object_id = OBJECT_ID(N'[dbo].[PO_PR_Mapping]'))
    ALTER TABLE [dbo].[PO_PR_Mapping] ADD CONSTRAINT [FK_PO_PR_Mapping_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PURCHASE_BUDGETS_USER' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_BUDGETS]'))
    ALTER TABLE [dbo].[PURCHASE_BUDGETS] ADD CONSTRAINT [FK_PURCHASE_BUDGETS_USER] FOREIGN KEY ([CreatedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PO_Approver' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [FK_PO_Approver] FOREIGN KEY ([ApprovedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PO_PR' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [FK_PO_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PO_Supplier' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_ORDERS]'))
    ALTER TABLE [dbo].[PURCHASE_ORDERS] ADD CONSTRAINT [FK_PO_Supplier] FOREIGN KEY ([SupplierID]) REFERENCES [dbo].[SUPPLIERS] ([SupplierID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PURCHASE_REQUESTS_REPF' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
    ALTER TABLE [dbo].[PURCHASE_REQUESTS] ADD CONSTRAINT [FK_PURCHASE_REQUESTS_REPF] FOREIGN KEY ([RepFID]) REFERENCES [dbo].[REPLENISHMENT_REQUESTS] ([RepFID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_PURCHASE_REQUESTS_USERS' AND parent_object_id = OBJECT_ID(N'[dbo].[PURCHASE_REQUESTS]'))
    ALTER TABLE [dbo].[PURCHASE_REQUESTS] ADD CONSTRAINT [FK_PURCHASE_REQUESTS_USERS] FOREIGN KEY ([CreatedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_RMDETAILS_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] ADD CONSTRAINT [FK_RMDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_RMDETAILS_RM' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMO_DETAILS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMO_DETAILS] ADD CONSTRAINT [FK_RMDETAILS_RM] FOREIGN KEY ([RMID]) REFERENCES [dbo].[RECEIVING_MEMOS] ([RMID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_RM_DR' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMOS] ADD CONSTRAINT [FK_RM_DR] FOREIGN KEY ([DRID]) REFERENCES [dbo].[DELIVERY_RECEIPTS] ([DRID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_RM_Receiver' AND parent_object_id = OBJECT_ID(N'[dbo].[RECEIVING_MEMOS]'))
    ALTER TABLE [dbo].[RECEIVING_MEMOS] ADD CONSTRAINT [FK_RM_Receiver] FOREIGN KEY ([ReceivedByUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REPF_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
    ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] ADD CONSTRAINT [FK_REPF_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REPF_OriginRequisition' AND parent_object_id = OBJECT_ID(N'[dbo].[REPLENISHMENT_REQUESTS]'))
    ALTER TABLE [dbo].[REPLENISHMENT_REQUESTS] ADD CONSTRAINT [FK_REPF_OriginRequisition] FOREIGN KEY ([OriginRequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REQDETAILS_ITEMS' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
    ALTER TABLE [dbo].[REQUISITION_DETAILS] ADD CONSTRAINT [FK_REQDETAILS_ITEMS] FOREIGN KEY ([ItemID]) REFERENCES [dbo].[ITEMS] ([ItemID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REQDETAILS_REQUISITIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITION_DETAILS]'))
    ALTER TABLE [dbo].[REQUISITION_DETAILS] ADD CONSTRAINT [FK_REQDETAILS_REQUISITIONS] FOREIGN KEY ([RequisitionID]) REFERENCES [dbo].[REQUISITIONS] ([RequisitionID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REQUISITIONS_Approver' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    ALTER TABLE [dbo].[REQUISITIONS] ADD CONSTRAINT [FK_REQUISITIONS_Approver] FOREIGN KEY ([DepartmentHeadUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_REQUISITIONS_Requestor' AND parent_object_id = OBJECT_ID(N'[dbo].[REQUISITIONS]'))
    ALTER TABLE [dbo].[REQUISITIONS] ADD CONSTRAINT [FK_REQUISITIONS_Requestor] FOREIGN KEY ([RequestorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_ROLE_PERMISSIONS_PERMISSIONS' AND parent_object_id = OBJECT_ID(N'[dbo].[ROLE_PERMISSIONS]'))
    ALTER TABLE [dbo].[ROLE_PERMISSIONS] ADD CONSTRAINT [FK_ROLE_PERMISSIONS_PERMISSIONS] FOREIGN KEY ([PermissionID]) REFERENCES [dbo].[PERMISSIONS] ([PermissionID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_ROLE_PERMISSIONS_ROLES' AND parent_object_id = OBJECT_ID(N'[dbo].[ROLE_PERMISSIONS]'))
    ALTER TABLE [dbo].[ROLE_PERMISSIONS] ADD CONSTRAINT [FK_ROLE_PERMISSIONS_ROLES] FOREIGN KEY ([RoleID]) REFERENCES [dbo].[ROLES] ([RoleID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_QUOTATIONS_PR' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
    ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] ADD CONSTRAINT [FK_QUOTATIONS_PR] FOREIGN KEY ([PRID]) REFERENCES [dbo].[PURCHASE_REQUESTS] ([PRID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_QUOTATIONS_SUPPLIERS' AND parent_object_id = OBJECT_ID(N'[dbo].[SUPPLIER_QUOTATIONS]'))
    ALTER TABLE [dbo].[SUPPLIER_QUOTATIONS] ADD CONSTRAINT [FK_QUOTATIONS_SUPPLIERS] FOREIGN KEY ([SupplierID]) REFERENCES [dbo].[SUPPLIERS] ([SupplierID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_USER_AUDIT_LOGS_Actor' AND parent_object_id = OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]'))
    ALTER TABLE [dbo].[USER_AUDIT_LOGS] ADD CONSTRAINT [FK_USER_AUDIT_LOGS_Actor] FOREIGN KEY ([ActorUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_USER_AUDIT_LOGS_Target' AND parent_object_id = OBJECT_ID(N'[dbo].[USER_AUDIT_LOGS]'))
    ALTER TABLE [dbo].[USER_AUDIT_LOGS] ADD CONSTRAINT [FK_USER_AUDIT_LOGS_Target] FOREIGN KEY ([TargetUserID]) REFERENCES [dbo].[USERS] ([UserID]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_USERS_ROLES' AND parent_object_id = OBJECT_ID(N'[dbo].[USERS]'))
    ALTER TABLE [dbo].[USERS] ADD CONSTRAINT [FK_USERS_ROLES] FOREIGN KEY ([RoleID]) REFERENCES [dbo].[ROLES] ([RoleID]);
GO

/* ============================================================
   6. BASELINE RBAC SEED

   Kini nga seed kay ang minimum nga kinahanglan sa app para
   makalogin ug makagamit sa permissions: 25 permissions,
   5 roles, role-permission matrix, ug ang admin account.
   Ang mga demo user (user3-user6) ug sample items kay wala
   giapil kay test data na - ang V003 ray nagseed sa items.

   Explicit ang IDs (IDENTITY_INSERT) para pareho sa live DB
   ug para ang RoleID = 1 kay sigurado nga Admin.
   ============================================================ */

-- 25 permissions
SET IDENTITY_INSERT [dbo].[PERMISSIONS] ON;
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 1)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (1, N'dashboard.view', N'View the dashboard');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 2)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (2, N'users.view', N'View user accounts');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 3)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (3, N'users.create', N'Create user accounts');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 4)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (4, N'users.update', N'Update user accounts');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 5)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (5, N'users.deactivate', N'Deactivate user accounts');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 6)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (6, N'users.assign_role', N'Assign allowed user roles');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 7)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (7, N'roles.view', N'View available roles');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 8)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (8, N'inventory.view', N'View inventory');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 9)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (9, N'inventory.create', N'Add inventory items');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 10)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (10, N'inventory.update', N'Update inventory items');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 11)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (11, N'inventory.adjust', N'Adjust inventory quantities');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 12)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (12, N'requisitions.view', N'View requisitions');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 13)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (13, N'requisitions.create', N'Create requisitions');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 14)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (14, N'requisitions.approve', N'Approve requisitions');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 15)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (15, N'requisitions.reject', N'Reject requisitions');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 16)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (16, N'purchasing.view', N'View purchasing records');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 17)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (17, N'purchasing.manage', N'Manage purchase requests and purchase orders');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 18)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (18, N'suppliers.view', N'View suppliers');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 19)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (19, N'suppliers.manage', N'Manage suppliers');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 20)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (20, N'receiving.view', N'View delivery and receiving records');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 21)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (21, N'receiving.manage', N'Record received deliveries');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 22)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (22, N'delivery.view', N'View delivery and acknowledgement records');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 23)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (23, N'delivery.manage', N'Issue items and manage acknowledgement receipts');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 24)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (24, N'reports.view', N'View system reports');
IF NOT EXISTS (SELECT 1 FROM [dbo].[PERMISSIONS] WHERE [PermissionID] = 25)
    INSERT INTO [dbo].[PERMISSIONS] ([PermissionID], [PermissionCode], [Description]) VALUES (25, N'settings.manage', N'Manage salon settings');
SET IDENTITY_INSERT [dbo].[PERMISSIONS] OFF;
GO

-- 5 roles
SET IDENTITY_INSERT [dbo].[ROLES] ON;
IF NOT EXISTS (SELECT 1 FROM [dbo].[ROLES] WHERE [RoleID] = 1)
    INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (1, N'Admin', N'Manages salon users, settings and overall operations.', 1);
IF NOT EXISTS (SELECT 1 FROM [dbo].[ROLES] WHERE [RoleID] = 2)
    INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (2, N'Manager', N'Supervises operations and handles requisition approvals.', 1);
IF NOT EXISTS (SELECT 1 FROM [dbo].[ROLES] WHERE [RoleID] = 3)
    INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (3, N'Inventory Staff', N'Manages inventory, receiving and releasing of items.', 1);
IF NOT EXISTS (SELECT 1 FROM [dbo].[ROLES] WHERE [RoleID] = 4)
    INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (4, N'Purchasing Staff', N'Handles purchase requests, quotations and purchase orders.', 1);
IF NOT EXISTS (SELECT 1 FROM [dbo].[ROLES] WHERE [RoleID] = 5)
    INSERT INTO [dbo].[ROLES] ([RoleID], [RoleName], [Description], [IsActive]) VALUES (5, N'Staff', N'Submits requisitions and views request status.', 1);
SET IDENTITY_INSERT [dbo].[ROLES] OFF;
GO

-- Role-permission matrix (isa ra ka set-based insert, idempotent)
INSERT INTO [dbo].[ROLE_PERMISSIONS] ([RoleID], [PermissionID])
SELECT r.[RoleID], p.[PermissionID]
FROM (VALUES
    (N'Admin', N'dashboard.view'),
    (N'Admin', N'delivery.manage'),
    (N'Admin', N'delivery.view'),
    (N'Admin', N'inventory.adjust'),
    (N'Admin', N'inventory.create'),
    (N'Admin', N'inventory.update'),
    (N'Admin', N'inventory.view'),
    (N'Admin', N'purchasing.manage'),
    (N'Admin', N'purchasing.view'),
    (N'Admin', N'receiving.manage'),
    (N'Admin', N'receiving.view'),
    (N'Admin', N'reports.view'),
    (N'Admin', N'requisitions.approve'),
    (N'Admin', N'requisitions.create'),
    (N'Admin', N'requisitions.reject'),
    (N'Admin', N'requisitions.view'),
    (N'Admin', N'roles.view'),
    (N'Admin', N'settings.manage'),
    (N'Admin', N'suppliers.manage'),
    (N'Admin', N'suppliers.view'),
    (N'Admin', N'users.assign_role'),
    (N'Admin', N'users.create'),
    (N'Admin', N'users.deactivate'),
    (N'Admin', N'users.update'),
    (N'Admin', N'users.view'),
    (N'Manager', N'dashboard.view'),
    (N'Manager', N'delivery.view'),
    (N'Manager', N'inventory.update'),
    (N'Manager', N'inventory.view'),
    (N'Manager', N'purchasing.view'),
    (N'Manager', N'receiving.view'),
    (N'Manager', N'reports.view'),
    (N'Manager', N'requisitions.approve'),
    (N'Manager', N'requisitions.create'),
    (N'Manager', N'requisitions.reject'),
    (N'Manager', N'requisitions.view'),
    (N'Manager', N'roles.view'),
    (N'Manager', N'suppliers.view'),
    (N'Manager', N'users.view'),
    (N'Inventory Staff', N'dashboard.view'),
    (N'Inventory Staff', N'delivery.manage'),
    (N'Inventory Staff', N'delivery.view'),
    (N'Inventory Staff', N'inventory.adjust'),
    (N'Inventory Staff', N'inventory.create'),
    (N'Inventory Staff', N'inventory.update'),
    (N'Inventory Staff', N'inventory.view'),
    (N'Inventory Staff', N'receiving.manage'),
    (N'Inventory Staff', N'receiving.view'),
    (N'Inventory Staff', N'requisitions.view'),
    (N'Purchasing Staff', N'dashboard.view'),
    (N'Purchasing Staff', N'inventory.view'),
    (N'Purchasing Staff', N'purchasing.manage'),
    (N'Purchasing Staff', N'purchasing.view'),
    (N'Purchasing Staff', N'reports.view'),
    (N'Purchasing Staff', N'requisitions.view'),
    (N'Purchasing Staff', N'suppliers.manage'),
    (N'Purchasing Staff', N'suppliers.view'),
    (N'Staff', N'dashboard.view'),
    (N'Staff', N'inventory.view'),
    (N'Staff', N'requisitions.create'),
    (N'Staff', N'requisitions.view')
) AS v ([RoleName], [PermissionCode])
INNER JOIN [dbo].[ROLES] r ON r.[RoleName] = v.[RoleName]
INNER JOIN [dbo].[PERMISSIONS] p ON p.[PermissionCode] = v.[PermissionCode]
WHERE NOT EXISTS
(
    SELECT 1 FROM [dbo].[ROLE_PERMISSIONS] rp
    WHERE rp.[RoleID] = r.[RoleID] AND rp.[PermissionID] = p.[PermissionID]
);
GO

-- Admin account (mag-change password sa first login)
IF NOT EXISTS (SELECT 1 FROM [dbo].[USERS] WHERE [Username] = N'admin')
    INSERT INTO [dbo].[USERS]
    (
        [LastName], [FirstName], [MiddleName], [Username], [PasswordHash],
        [Email], [RoleID], [IsActive], [FailedLoginAttempts], [LockoutEnd],
        [MustChangePassword], [PasswordChangedAt]
    )
    VALUES
    (
        N'Salon', N'Administrator', NULL, N'admin', N'PBKDF2-SHA256:100000:Z1JZjXq1BmqAW5uBuM3OyKLTqTgoP5lO5p4FmrN9KxQ=:vI5R1v//4OCz0Nvb2ijoyElsgLWjZgC8GMtrrrfIG1F+Zv08+sK8sRpVCt/cppAz+3MJqHOnHCQNdM9gNCKg2w==',
        N'admin@justmakeover.local', 1, 1, 0, NULL,
        1, SYSDATETIME()
    );
GO
