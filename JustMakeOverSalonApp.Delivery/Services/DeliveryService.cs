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

        // Kani nga method nagkuha sa on-demand signature sa AR para sa
        // "View signature" modal (delivery.view permission).
        public Task<Models.DeliverySignatureRecord> GetSignatureAsync(CurrentUser actor, int deliveryID)
        {
            actor.RequirePermission(PermissionCodes.DeliveryView);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            return Task.FromResult(repository.GetSignature(actor.UserID, deliveryID));
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
        public Task CompleteAsync(CurrentUser actor, int deliveryID, string signature)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            // Kani nga validation kay parehas sa database guard: kinahanglan
            // naay drawn signature sa dili pa ma-complete ang delivery.
            if (string.IsNullOrWhiteSpace(signature))
            {
                throw new BusinessException("A signature is required before completing the delivery.");
            }

            if (!signature.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
            {
                throw new BusinessException("The signature image is not valid.");
            }

            if (signature.Length > 2000000)
            {
                throw new BusinessException("The signature image is too large.");
            }

            repository.Complete(actor.UserID, deliveryID, signature);
            return Task.CompletedTask;
        }

        // Kani nga method nag-balik sa AR ngadto sa 'Generated' para
        // ma-issue pag-usab human ma-correct ang discrepancy.
        public Task ReissueAsync(CurrentUser actor, int deliveryID)
        {
            actor.RequirePermission(PermissionCodes.DeliveryManage);

            if (deliveryID <= 0)
            {
                throw new BusinessException("A valid acknowledgement receipt is required.");
            }

            repository.Reissue(actor.UserID, deliveryID);
            return Task.CompletedTask;
        }
    }
}
