USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetOverview
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

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetReceipt
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
