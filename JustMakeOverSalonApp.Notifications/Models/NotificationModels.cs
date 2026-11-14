using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Notifications.Models
{
    // Kani nga model kay para sa usa ka notification sa current user
    // (gikan sa NOTIFICATIONS table - generated sa issuance/receiving
    // engine per flowchart Figure 8).
    public sealed class NotificationRecord
    {
        public long NotificationID { get; set; }
        public string NotificationType { get; set; }
        public string Title { get; set; }
        public string Message { get; set; }
        public string RelatedEntityType { get; set; }
        public int? RelatedEntityID { get; set; }
        public bool IsRead { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    // Kani nga model kay nagdala sa TANANG page data sa usa ka call.
    public sealed class NotificationsOverview
    {
        public IList<NotificationRecord> Notifications { get; set; }
        public int UnreadCount { get; set; }
    }
}
