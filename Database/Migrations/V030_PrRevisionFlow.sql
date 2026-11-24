/*
    V030_PrRevisionFlow.sql

    Purchasing reject flow:
    PO Rejected -> Original PR Returned for Revision -> PR Revised ->
    New PO Generated -> Reapproval.

    Kini nga migration kay naghuman sa flow:

    1. PO REJECTED -> NOTIFY REQUESTOR
       Ang flowchart moingon "System notifies requestor: hold or
       revise request". Ang existing proc kay nag-notify ra sa
       naghimo sa PR (Purchasing). Kini nga trigger kay nagdugang
       og notification sa requisition owner, nga naka-link sa
       Requisition page (RelatedEntityType = 'REQUISITION').

    2. PR REVISED -> CLEAR STALE REJECTION ALERTS
       Kung gi-reopen ang rejected PR para i-revise (Rejected -> Open),
       i-mark read ang daan nga PO_REJECTED notifications para wala nay
       stale rejection sa bell. Ang Purchasing mo-update dayon sa
       quotations ug mo-create og bag-ong PO para reapproval.

    Idempotent: CREATE OR ALTER ra, walay DROP.
*/

USE JustMakeOverSalonDB;
GO

/* ============================================================
   1. PO NOTIFICATIONS (existing + requestor rejection notice)
   ============================================================ */

CREATE OR ALTER TRIGGER dbo.trg_Purchasing_PONotifications
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
      AND r.RoleName IN ('Admin', 'Manager')
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
END;
GO

/* ============================================================
   2. PR REVISED -> CLEAR STALE PO REJECTION ALERTS
   ============================================================ */

CREATE OR ALTER TRIGGER dbo.trg_Purchasing_PrRevision
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
