using System;
using System.Collections.Generic;
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

        public Task<Models.DeliveryOverview> LoadOverviewAsync(
            CurrentUser actor)
        {
            RequireDeliveryViewer(actor);

            return Task.FromResult(
                repository.LoadOverview(actor.UserID));
        }

        public Task<Models.DeliveryReceiptRecord> GetReceiptAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryViewer(actor);
            ValidateDeliveryID(deliveryID);

            var receipt = repository.GetReceipt(
                actor.UserID,
                deliveryID);

            if (receipt == null)
            {
                throw new BusinessException(
                    "The acknowledgement receipt could not be found.");
            }

            return Task.FromResult(receipt);
        }

        // Kani nga method nagkuha sa real Correction Report print data
        // (header + items + signature history) on-demand.
        public Task<Dictionary<string, object>> GetCorrectionReportAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryViewer(actor);
            ValidateDeliveryID(deliveryID);

            var report = repository.GetCorrectionReport(
                actor.UserID,
                deliveryID);

            if (report == null)
            {
                throw new BusinessException(
                    "The correction report could not be found.");
            }

            return Task.FromResult(report);
        }

        // Inventory Staff or Admin generates the AR.
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

        // Inventory Staff or Admin issues the items uban sa signature.
        public Task MarkIssuedAsync(
            CurrentUser actor,
            int deliveryID,
            string signature)
        {
            RequireDeliveryManager(actor);
            ValidateDeliveryID(deliveryID);
            ValidateSignature(
                signature,
                "A signature is required before issuing the items.");

            repository.MarkIssued(
                actor.UserID,
                deliveryID,
                signature);

            return Task.CompletedTask;
        }

        // Any receipt owner, or Admin, can note a discrepancy.
        // SQL verifies ownership using the authenticated actor.UserID.
        public Task NoteDiscrepancyAsync(
            CurrentUser actor,
            int deliveryID,
            string notes)
        {
            RequireDeliveryViewer(actor);
            ValidateDeliveryID(deliveryID);

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

        // Inventory Staff or Admin records the correction.
        public Task RecordCorrectionAsync(
            CurrentUser actor,
            int deliveryID,
            string notes)
        {
            RequireDeliveryManager(actor);
            ValidateDeliveryID(deliveryID);

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

        // Any receipt owner, or Admin, can sign and complete.
        // SQL verifies ownership, status, discrepancy resolution,
        // and stock availability.
        public Task CompleteAsync(
            CurrentUser actor,
            int deliveryID,
            string signature)
        {
            RequireDeliveryViewer(actor);
            ValidateDeliveryID(deliveryID);
            ValidateSignature(
                signature,
                "A signature is required before completing the delivery.");

            repository.Complete(
                actor.UserID,
                deliveryID,
                signature);

            return Task.CompletedTask;
        }

        // Inventory Staff or Admin returns the corrected AR
        // to Generated so the items can be issued again.
        public Task ReissueAsync(
            CurrentUser actor,
            int deliveryID)
        {
            RequireDeliveryManager(actor);
            ValidateDeliveryID(deliveryID);

            repository.Reissue(
                actor.UserID,
                deliveryID);

            return Task.CompletedTask;
        }

        private static void ValidateDeliveryID(int deliveryID)
        {
            if (deliveryID <= 0)
            {
                throw new BusinessException(
                    "A valid acknowledgement receipt is required.");
            }
        }

        // Kani nga helper kay shared validation sa tanang signature steps
        // (issue ug complete), para usa ra ang rules sa tibuok module.
        private static void ValidateSignature(
            string signature,
            string missingMessage)
        {
            if (string.IsNullOrWhiteSpace(signature))
            {
                throw new BusinessException(missingMessage);
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
    }
}