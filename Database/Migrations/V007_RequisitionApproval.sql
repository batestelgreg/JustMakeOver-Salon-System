
/*
    V007 - Requisition Approval

    Kani nga migration kay para mahatagan ang Manager
    og inventory.update permission para maka-approve
    ug requisitions ug maka-reserve sa inventory.

    Apil pud ang requisitions.create permission para
    maka-submit og new requisitions ang Manager.
*/

INSERT INTO ROLE_PERMISSIONS (RoleID, PermissionID)
SELECT
    r.RoleID,
    p.PermissionID
FROM ROLES r
CROSS JOIN PERMISSIONS p
WHERE r.RoleName = 'Manager'
  AND p.PermissionCode = 'inventory.update'
  AND NOT EXISTS
  (
      SELECT 1
      FROM ROLE_PERMISSIONS rp
      WHERE rp.RoleID = r.RoleID
        AND rp.PermissionID = p.PermissionID
  );
GO

INSERT INTO ROLE_PERMISSIONS (RoleID, PermissionID)
SELECT
    r.RoleID,
    p.PermissionID
FROM ROLES r
CROSS JOIN PERMISSIONS p
WHERE r.RoleName = 'Manager'
  AND p.PermissionCode = 'requisitions.create'
  AND NOT EXISTS
  (
      SELECT 1
      FROM ROLE_PERMISSIONS rp
      WHERE rp.RoleID = r.RoleID
        AND rp.PermissionID = p.PermissionID
  );
GO

CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Approve
    @RequisitionID INT,
    @ApproverUserID INT
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
            FROM USERS u
            WHERE u.UserID = @ApproverUserID
              AND u.IsActive = 1
              AND EXISTS
              (
                  SELECT 1
                  FROM ROLE_PERMISSIONS rp
                  INNER JOIN PERMISSIONS p
                      ON p.PermissionID = rp.PermissionID
                  WHERE rp.RoleID = u.RoleID
                    AND p.PermissionCode = 'requisitions.approve'
              )
              AND EXISTS
              (
                  SELECT 1
                  FROM ROLE_PERMISSIONS rp
                  INNER JOIN PERMISSIONS p
                      ON p.PermissionID = rp.PermissionID
                  WHERE rp.RoleID = u.RoleID
                    AND p.PermissionCode = 'inventory.update'
              )
        )
        BEGIN
            THROW 50001, 'You do not have permission to approve requisitions.', 1;
        END;

        BEGIN TRANSACTION;

        SELECT @RequestorUserID = RequestorUserID
        FROM REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50002, 'Requisition not found or is no longer pending.', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM REQUISITION_DETAILS
            WHERE RequisitionID = @RequisitionID
        )
        BEGIN
            THROW 50003, 'This requisition has no items.', 1;
        END;

        UPDATE REQUISITIONS
        SET
            Status = 'Approved',
            DepartmentHeadUserID = @ApproverUserID
        WHERE RequisitionID = @RequisitionID;

        UPDATE REQUISITION_DETAILS
        SET
            QuantityApproved = QuantityRequested
        WHERE RequisitionID = @RequisitionID;

        DECLARE requisition_items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemID, QuantityRequested
            FROM REQUISITION_DETAILS
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

        INSERT INTO USER_AUDIT_LOGS
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

        INSERT INTO NOTIFICATIONS
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


CREATE OR ALTER PROCEDURE dbo.usp_Requisition_Reject
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
            FROM USERS u
            WHERE u.UserID = @RejectorUserID
              AND u.IsActive = 1
              AND EXISTS
              (
                  SELECT 1
                  FROM ROLE_PERMISSIONS rp
                  INNER JOIN PERMISSIONS p
                      ON p.PermissionID = rp.PermissionID
                  WHERE rp.RoleID = u.RoleID
                    AND p.PermissionCode = 'requisitions.reject'
              )
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
        FROM REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
        WHERE RequisitionID = @RequisitionID
          AND Status = 'Pending';

        IF @RequestorUserID IS NULL
        BEGIN
            THROW 50006, 'Requisition not found or is no longer pending.', 1;
        END;

        UPDATE REQUISITIONS
        SET
            Status = 'Rejected',
            RejectionReason = @Reason,
            DepartmentHeadUserID = @RejectorUserID
        WHERE RequisitionID = @RequisitionID;

        UPDATE REQUISITION_DETAILS
        SET Status = 'Rejected'
        WHERE RequisitionID = @RequisitionID;

        INSERT INTO USER_AUDIT_LOGS
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

        INSERT INTO NOTIFICATIONS
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
