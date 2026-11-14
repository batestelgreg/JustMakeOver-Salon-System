using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Notifications.Repositories;

namespace JustMakeOverSalonApp.Notifications.Services
{
    // Kani nga service kay nagdala sa business rules sa Notifications module.
    // Ang tanang user kay makakita sa IYANG KAUGALINGONG notifications
    // (dashboard.view ang gate sa sidebar) - walay lain makakita.
    public sealed class NotificationsService
    {
        private readonly Repositories.NotificationsRepository repository;

        public NotificationsService(Repositories.NotificationsRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa mga notification sa current user.
        public Task<Models.NotificationsOverview> LoadOverviewAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.DashboardView);
            return Task.FromResult(repository.LoadByUser(actor.UserID));
        }

        // Kani nga method nag-mark read: notificationID <= 0 o empty = tanan unread.
        public Task MarkReadAsync(CurrentUser actor, long notificationID)
        {
            actor.RequirePermission(PermissionCodes.DashboardView);

            if (notificationID < 0)
            {
                throw new BusinessException("A valid notification is required.");
            }

            repository.MarkRead(
                actor.UserID,
                notificationID > 0 ? notificationID : (long?)null);

            return Task.CompletedTask;
        }
    }
}
