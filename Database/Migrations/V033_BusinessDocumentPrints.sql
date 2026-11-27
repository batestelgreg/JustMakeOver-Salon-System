/*
    V033_BusinessDocumentPrints.sql

    Real business-format printable documents for the remaining records:

    1. Purchase Order (PO) print
    2. Requisition Form (RF) print
    3. Receiving Report (RR) print
    4. Stock Card per inventory item
    5. Return Slip for rejected supplier deliveries
    6. Correction Report for AR discrepancies/corrections
    7. Replenishment Request print

    Kini nga migration kay nag-dugang lang ug ON-DEMAND print queries.
    Dili ni mo-apil sa page load, so one DB call gihapon ang matag page.
    Ang matag print button kay mo-call sa matching procedure ug ang
    procedure ra ang nagbalik sa header + detail result sets.

    Idempotent: CREATE OR ALTER ra, walay DROP.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. PURCHASE ORDER PRINT
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_GetPurchaseOrderPrint
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
   2. REQUISITION FORM PRINT
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Requisition_GetPrint
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

    /* Result set 1: requisition header. */
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
        ) AS SalonTagline
    FROM dbo.REQUISITIONS r
    INNER JOIN dbo.USERS requestor
        ON requestor.UserID = r.RequestorUserID
    LEFT JOIN dbo.USERS head
        ON head.UserID = r.DepartmentHeadUserID
    WHERE r.RequisitionID = @RequisitionID;

    /* Result set 2: requisition line items. */
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

/* ============================================================
   3. RECEIVING REPORT PRINT
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Receiving_GetPrint
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

/* ============================================================
   4. STOCK CARD PRINT
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Inventory_GetStockCard
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
   5. RETURN SLIP (REJECTED SUPPLIER DELIVERY)
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Purchasing_GetReturnSlip
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
   6. CORRECTION REPORT (AR DISCREPANCY / CORRECTION)
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetCorrectionReport
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

    /* Result set 1: correction report header. */
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
        ) AS SalonTagline
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
    WHERE d.DeliveryID = @DeliveryID;

    /* Result set 2: AR line items. */
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

    /* Result set 3: preserved signature history (audit trail). */
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

/* ============================================================
   7. REPLENISHMENT REQUEST PRINT
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_Inventory_GetReplenishmentPrint
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
