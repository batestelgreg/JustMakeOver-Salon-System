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
CREATE OR ALTER PROCEDURE usp_Notifications_GetByUser
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
CREATE OR ALTER PROCEDURE usp_Notifications_MarkRead
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
