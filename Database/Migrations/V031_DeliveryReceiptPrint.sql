/*
    V031_DeliveryReceiptPrint.sql

    Real Acknowledgement Receipt print.

    Kini nga migration kay nagdugang sa on-demand nga receipt query para
    sa Delivery page. Usa ra ka stored procedure ang gigamit sa print
    button, ug duha ka result set ang iyang gibalik:

    1. Receipt header — AR code, requisition, requestor, department head,
       generated/issued/signed dates, status, notes, signature image,
       ug ang salon branding gikan sa SYSTEM_SETTINGS.
    2. Receipt line items — item code, description, unit, ug quantity.

    On-demand ni (print ra ang mo-call), so one DB call gihapon ang
    page load sa Delivery. Permission: delivery.view (parehas sa list).

    Idempotent: CREATE OR ALTER ra, walay DROP.
*/

USE JustMakeOverSalonDB;
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

    /* Wala makita ang receipt: walay result set, service ang mo-message. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DELIVERIES
        WHERE DeliveryID = @DeliveryID
    )
        RETURN;

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
        ) AS SalonTagline
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
