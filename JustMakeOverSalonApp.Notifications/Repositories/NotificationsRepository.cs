using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Notifications.Models;

namespace JustMakeOverSalonApp.Notifications.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Notifications module.
    // Kini nga file kay iya ra sa Notifications developer - walay laing mo-edit ani.
    public sealed class NotificationsRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public NotificationsRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa mga notification sa user + unread count
        // sa usa ra ka database call (ang count gi-compute sa listahang
        // nabasa na - walay extra nga roundtrip).
        public NotificationsOverview LoadByUser(int actorUserID)
        {
            var notifications = new List<NotificationRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Notifications_GetByUser", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        notifications.Add(MapNotification(reader));
                    }
                }
            }

            var unreadCount = 0;
            foreach (var notification in notifications)
            {
                if (!notification.IsRead)
                {
                    unreadCount++;
                }
            }

            return new NotificationsOverview
            {
                Notifications = notifications,
                UnreadCount = unreadCount
            };
        }

        // Kani nga method nag-mark read sa usa ka notification (kung naay ID)
        // o sa tanan unread sa user. Ang proc kay naka-scope sa RecipientUserID
        // mao nga dili ma-mark read sa laing user ang dili iya.
        public void MarkRead(int actorUserID, long? notificationID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Notifications_MarkRead", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@NotificationID", SqlDbType.BigInt).Value =
                    notificationID.HasValue ? (object)notificationID.Value : DBNull.Value;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga mapper nag-convert sa row ngadto sa NotificationRecord.
        private static NotificationRecord MapNotification(SqlDataReader reader)
        {
            return new NotificationRecord
            {
                NotificationID = reader.GetInt64(0),
                NotificationType = reader.GetString(1),
                Title = reader.GetString(2),
                Message = reader.GetString(3),
                RelatedEntityType = reader.IsDBNull(4) ? null : reader.GetString(4),
                RelatedEntityID = reader.IsDBNull(5) ? (int?)null : reader.GetInt32(5),
                IsRead = reader.GetBoolean(6),
                CreatedAt = reader.GetDateTime(7)
            };
        }
    }
}
