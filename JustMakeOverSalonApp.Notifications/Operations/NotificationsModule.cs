using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Notifications.Operations
{
    // Kani nga class kay nag-register sa tanang bridge operations sa Notifications module.
    // Kini nga file kay iya ra sa Notifications developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class NotificationsModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.NotificationsService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.NotificationsService(
                new Repositories.NotificationsRepository(new SqlConnectionFactory()));

            // Kani mga operation names kay ang bridge contract sa Notifications page.
            registry.Register("NotificationsList", HandleNotificationsListAsync);
            registry.Register("NotificationsMarkRead", HandleNotificationsMarkReadAsync);
        }

        // Kani nga handler nagdala sa TANANG page data sa usa ra ka response
        // (listahan + unread count para sa bell badge sa topbar).
        private async Task HandleNotificationsListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadOverviewAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong ano-on ang names diri).
            context.SendResponse(requestID, true, new
            {
                notifications = overview.Notifications,
                unreadCount = overview.UnreadCount
            }, null);
        }

        // Kani nga handler nag-mark read sa usa ka notification (kung naay ID)
        // o sa tanan unread sa user (kung empty ang notificationID).
        private async Task HandleNotificationsMarkReadAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var idText = context.GetValueAsString(payload, "notificationID");
            long.TryParse(idText, out long notificationID);

            await service.MarkReadAsync(actor, notificationID);
            context.SendResponse(requestID, true, null, null);
        }
    }
}
