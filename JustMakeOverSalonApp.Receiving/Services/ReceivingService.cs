using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Services;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Receiving.Repositories;

namespace JustMakeOverSalonApp.Receiving.Services
{
    // Kani nga service kay nagdala sa business rules sa Receiving module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class ReceivingService
    {
        private readonly Repositories.ReceivingRepository repository;

        public ReceivingService(Repositories.ReceivingRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa TANANG page data sa usa ra ka call
        // (pending queue + receiving history).
        public Task<Models.ReceivingOverview> LoadOverviewAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.ReceivingView);
            return Task.FromResult(repository.LoadOverview(actor.UserID));
        }

        // Kani nga method nag-submit sa receiving (flowchart Figure 8.B):
        // record sa receipt + increase sa stock + allocation sa mga naghuwat
        // nga reservations. Ang tinuod nga transaction kay sa shared engine
        // (usp_Inventory_ReceiveStock) mao nga usa ra ang receiving flow.
        public Task SubmitAsync(
            CurrentUser actor,
            int itemID,
            int quantityReceived,
            int? repFID,
            string remarks,
            string signatureImage,
            bool confirmed)
        {
            actor.RequirePermission(PermissionCodes.ReceivingManage);

            if (itemID <= 0)
            {
                throw new BusinessException("A valid item is required.");
            }

            if (quantityReceived <= 0)
            {
                throw new BusinessException(
                    "The received quantity must be greater than zero.");
            }

            if (!confirmed)
            {
                throw new BusinessException(
                    "Please confirm your signature before recording the receipt.");
            }

            DocumentSignatureService.ValidateSignatureImage(
                signatureImage,
                "A signature is required to record the receiving report.");

            repository.SubmitReceive(
                actor.UserID,
                itemID,
                quantityReceived,
                repFID.HasValue && repFID.Value > 0 ? repFID : null,
                remarks,
                signatureImage,
                true);

            return Task.CompletedTask;
        }

        // Kani nga method nag-receive sa checked DR gikan sa Purchasing.
        public Task ReceiveCheckedDRAsync(
            CurrentUser actor,
            int drID,
            string signatureImage,
            bool confirmed)
        {
            actor.RequirePermission(PermissionCodes.ReceivingManage);

            if (drID <= 0)
            {
                throw new BusinessException("A valid delivery receipt is required.");
            }

            if (!confirmed)
            {
                throw new BusinessException(
                    "Please confirm your signature before receiving the checked delivery.");
            }

            DocumentSignatureService.ValidateSignatureImage(
                signatureImage,
                "A signature is required to receive a checked delivery.");

            repository.ReceiveCheckedDR(actor.UserID, drID, signatureImage, true);

            return Task.CompletedTask;
        }

        // Kani nga method nagkuha sa real Receiving Report print data
        // on-demand. Dili ni mo-apil sa page load.
        public Task<Dictionary<string, object>> GetPrintAsync(
            CurrentUser actor,
            long inventoryLogID)
        {
            actor.RequirePermission(PermissionCodes.ReceivingView);

            if (inventoryLogID <= 0)
            {
                throw new BusinessException(
                    "A valid receiving record is required.");
            }

            var receipt = repository.GetPrint(
                actor.UserID,
                inventoryLogID);

            if (receipt == null)
            {
                throw new BusinessException(
                    "The receiving record could not be found.");
            }

            return Task.FromResult(receipt);
        }
    }
}
