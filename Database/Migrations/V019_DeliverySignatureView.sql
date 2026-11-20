/*
    V019_DeliverySignatureView.sql

    Kini nga migration kay nagdugang sa "View signature" support sa
    Delivery page:

    1. usp_Delivery_GetOverview — parehas sa V010, pero naa nay
       HasSignature column aron ang UI mahibalo kung naay tipigan nga
       e-signature ang AR (dili na kinahanglan mag-fetch kung wala).

    2. usp_Delivery_GetSignature — on-demand fetch sa signature image
       (PNG data URL) uban sa signer ug timestamp. Dili ni mo-apil sa
       page load, so one DB call gihapon ang page.

    Re-runnable (CREATE OR ALTER).
*/

USE JustMakeOverSalonDB;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetOverview
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
          AND p.PermissionCode = N'delivery.view'
    )
        THROW 50400, 'You do not have permission to view deliveries.', 1;

    -- Resultset 1: allocated requisitions (fully reserved na tanang
    -- items ug walay open nga AR pa) — ang START sa Figure 10.
    SELECT r.RequisitionID,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName,
           r.RequestDate,
           r.RequiredDate,
           r.Justification,
           (SELECT STRING_AGG(CONCAT(i.ItemName, N' (Qty: ',
                        CAST(ISNULL(rd.QuantityApproved, rd.QuantityRequested) AS NVARCHAR(20)),
                        N')'), N'; ')
                WITHIN GROUP (ORDER BY rd.RequisitionDetailID)
            FROM REQUISITION_DETAILS rd
            INNER JOIN ITEMS i ON i.ItemID = rd.ItemID
            WHERE rd.RequisitionID = r.RequisitionID) AS ItemsSummary
    FROM REQUISITIONS r
    INNER JOIN USERS reqUser ON reqUser.UserID = r.RequestorUserID
    WHERE r.Status = N'Approved'
      AND EXISTS (SELECT 1 FROM REQUISITION_DETAILS rd
                  WHERE rd.RequisitionID = r.RequisitionID)
      AND NOT EXISTS (SELECT 1 FROM REQUISITION_DETAILS rd
                      WHERE rd.RequisitionID = r.RequisitionID
                        AND rd.Status IN (N'Pending', N'Partially Fulfilled'))
      AND NOT EXISTS (SELECT 1 FROM DELIVERIES d
                      WHERE d.RequisitionID = r.RequisitionID
                        AND d.Status IN (N'Generated', N'Issued'))
    ORDER BY r.RequestDate;

    -- Resultset 2: AR records (newest first). Ang HasSignature kay
    -- ika-12 column (index 11 sa reader) — kini ra ang gidugang sa V010.
    SELECT d.DeliveryID,
           d.ARCode,
           d.RequisitionID,
           CONCAT(reqUser.FirstName, ' ', reqUser.LastName) AS RequestorName,
           d.GeneratedDate,
           d.IssuedDate,
           d.SignedDate,
           CONCAT(signedUser.FirstName, ' ', signedUser.LastName) AS SignedByName,
           d.DiscrepancyNotes,
           d.Status,
           (SELECT STRING_AGG(CONCAT(i.ItemName, N' (Qty: ',
                        CAST(di.Quantity AS NVARCHAR(20)), N')'), N'; ')
                WITHIN GROUP (ORDER BY di.DeliveryItemID)
            FROM DELIVERY_ITEMS di
            INNER JOIN ITEMS i ON i.ItemID = di.ItemID
            WHERE di.DeliveryID = d.DeliveryID) AS ItemsSummary,
           CAST(CASE WHEN d.ESignatureData IS NULL THEN 0 ELSE 1 END AS BIT) AS HasSignature
    FROM DELIVERIES d
    INNER JOIN USERS reqUser ON reqUser.UserID = d.RequestorUserID
    LEFT JOIN USERS signedUser ON signedUser.UserID = d.SignedByUserID
    ORDER BY d.GeneratedDate DESC, d.DeliveryID DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Delivery_GetSignature
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
