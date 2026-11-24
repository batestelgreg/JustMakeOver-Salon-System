using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Delivery.Services
{
    public sealed class DeliveryService
    {
        private readonly Repositories.DeliveryRepository repository;

        public DeliveryService(
            Repositories.DeliveryRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Load allocated requisitions and acknowledgement receipts.
        public Task<Models.DeliveryOverview> LoadOverviewAsync(
            CurrentUser actor)
        {
            RequireDeliveryViewer(actor);

            return Task.FromResult(
                repository.LoadOverview(actor.UserID));
        }

        // Load the saved signature when requested.
        public Task<Models.DeliverySignatureRecord> GetSignatureAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryViewer(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            return Task.FromResult(
                repository.GetSignature(
                    actor.UserID,
                    deliveryID));
        }

        // Inventory Staff or Admin can generate an AR.
        public Task<Tuple<int, string>> GenerateARAsync(
            CurrentUser actor,
            int requisitionID)
        {
            RequireDeliveryManager(actor);

            if (requisitionID <= 0)
            {
                throw new BusinessException(
                    "A valid requisition is required.");
            }

            return Task.FromResult(
                repository.GenerateAR(
                    actor.UserID,
                    requisitionID));
        }

        // Inventory Staff or Admin can issue the items.
        public Task MarkIssuedAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryManager(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            repository.MarkIssued(
                actor.UserID,
                deliveryID);

            return Task.CompletedTask;
        }

        // Requestor or Admin can note a discrepancy.
        // SQL additionally verifies that the Requestor owns the receipt.
        public Task NoteDiscrepancyAsync(
            CurrentUser actor,
            int deliveryID,
            string notes)
        {
            RequireAcknowledger(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            if (string.IsNullOrWhiteSpace(notes))
            {
                throw new BusinessException(
                    "A discrepancy note is required.");
            }

            repository.NoteDiscrepancy(
                actor.UserID,
                deliveryID,
                notes.Trim());

            return Task.CompletedTask;
        }

        // Inventory Staff or Admin records the replacement or correction.
        public Task RecordCorrectionAsync(
            CurrentUser actor,
            int deliveryID,
            string notes)
        {
            RequireDeliveryManager(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            if (string.IsNullOrWhiteSpace(notes))
            {
                throw new BusinessException(
                    "The correction details are required.");
            }

            repository.RecordCorrection(
                actor.UserID,
                deliveryID,
                notes.Trim());

            return Task.CompletedTask;
        }

        // Requestor or Admin can sign and complete the receipt.
        // SQL verifies ownership, receipt status, discrepancy resolution,
        // and stock availability before processing completion.
        public Task CompleteAsync(
            CurrentUser actor,
            int deliveryID,
            string signature)
        {
            RequireAcknowledger(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            if (string.IsNullOrWhiteSpace(signature))
            {
                throw new BusinessException(
                    "A signature is required before completing the delivery.");
            }

            if (!signature.StartsWith(
                    "data:image/",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new BusinessException(
                    "The signature image is not valid.");
            }

            if (signature.Length > 2000000)
            {
                throw new BusinessException(
                    "The signature image is too large.");
            }

            repository.Complete(
                actor.UserID,
                deliveryID,
                signature);

            return Task.CompletedTask;
        }

        // Return the corrected receipt to Generated for another issue.
        public Task ReissueAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryManager(actor);

            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }

            repository.Reissue(
                actor.UserID,
                deliveryID);

            return Task.CompletedTask;
        }

        private static void RequireDeliveryViewer(
            CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException(
                    "Please sign in first.");
            }

            actor.RequirePermission(
                PermissionCodes.DeliveryView);
        }

        private static void RequireDeliveryManager(
            CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException(
                    "Please sign in first.");
            }

            actor.RequirePermission(
                PermissionCodes.DeliveryManage);

            if (actor.RoleName != "Admin" &&
                actor.RoleName != "Inventory Staff")
            {
                throw new BusinessException(
                    "Only Inventory Staff or Admin can manage delivery issuance and corrections.");
            }
        }

        private static void RequireAcknowledger(
            CurrentUser actor)
        {
            RequireDeliveryViewer(actor);

            if (actor.RoleName != "Admin" &&
                actor.RoleName != "Requestor")
            {
                throw new BusinessException(
                    "Only the Requestor or Admin can acknowledge a delivery.");
            }

            // V028 checks receipt ownership in SQL.
        }
    }
}