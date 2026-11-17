using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Delivery.Repositories;

namespace JustMakeOverSalonApp.Delivery.Services
{
    // Kani nga service kay nagdala sa business rules sa Delivery module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class DeliveryService
    {
        private readonly Repositories.DeliveryRepository repository;

        public DeliveryService(Repositories.DeliveryRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa TANANG page data sa usa ra ka call
        // (allocated requisitions + AR records).
        public Task<Models.DeliveryOverview> LoadOverviewAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.DeliveryView);
            return Task.FromResult(repository.LoadOverview(actor.UserID));
        }

        // Kani nga method nag-generate sa AR (Figure 10 step 1).
        public Task<Tuple<int, string>> GenerateARAsync(CurrentUser actor, int requisitionID)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (requisitionID <= 0)
            {
                throw new BusinessException("A valid requisition is required.");
            }

            return Task.FromResult(repository.GenerateAR(actor.UserID, requisitionID));
        }

        // Kani nga method nag-mark issued sa AR (issue step).
        public Task MarkIssuedAsync(CurrentUser actor, int deliveryID)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            repository.MarkIssued(actor.UserID, deliveryID);
            return Task.CompletedTask;
        }

        // Kani nga method nag-note discrepancy sa AR (discrepancy branch).
        public Task NoteDiscrepancyAsync(CurrentUser actor, int deliveryID, string notes)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            if (string.IsNullOrWhiteSpace(notes))
            {
                throw new BusinessException("A discrepancy note is required.");
            }

            repository.NoteDiscrepancy(actor.UserID, deliveryID, notes.Trim());
            return Task.CompletedTask;
        }

        // Kani nga method nag-complete sa AR: e-sign + deduction +
        // requisition Fulfilled + requester notification.
        public Task CompleteAsync(CurrentUser actor, int deliveryID)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            repository.Complete(actor.UserID, deliveryID);
            return Task.CompletedTask;
        }
    }
}
