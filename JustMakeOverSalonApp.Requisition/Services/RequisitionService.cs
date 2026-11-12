using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Requisition.Models;
using System;
using System.Collections.Generic;


namespace JustMakeOverSalonApp.Requisition.Services
{
    // Kani nga service kay nagdala sa business rules sa Requisition module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class RequisitionService
    {
        private readonly Repositories.RequisitionRepository repository;

        public RequisitionService(Repositories.RequisitionRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        /* Diri ibutang ang imong service methods. Pananglitan sa pattern:
        public Task LoadSomethingAsync(CurrentUser actor)
        {
            // Kani nga permission check kay backend-side, dili lang frontend.
            actor.RequirePermission("<module>.view");

            return Task.Run(() =>
            {
                // Kani nga lugar kay para sa validation + repository call.
                throw new BusinessException("This operation is not yet implemented.");
            });
        }
        */


        // Load active items for the requisition form.
        public List<ItemRecord> LoadActiveItems(CurrentUser actor)
        {
            actor.RequirePermission("requisitions.view");

            return repository.GetActiveItems();
        }


        // Create a new requisition.
        public int CreateRequisition(
            CurrentUser actor,
            DateTime requiredDate,
            string justification,
            List<RequisitionDetailModel> items)
        {
            // Check the user's permission.
            actor.RequirePermission("requisitions.create");

            // Validate the required date.
            if (requiredDate.Date < DateTime.Today)
            {
                throw new ArgumentException(
                    "Required date cannot be in the past.");
            }

            // Validate the justification.
            if (string.IsNullOrWhiteSpace(justification))
            {
                throw new ArgumentException(
                    "Please provide a justification.");
            }

            if (justification.Length > 500)
            {
                throw new ArgumentException(
                    "Justification cannot exceed 500 characters.");
            }

            // Check whether at least one item was selected.
            if (items == null || items.Count == 0)
            {
                throw new ArgumentException(
                    "Please select at least one item.");
            }

            // Validate each selected item.
            foreach (var item in items)
            {
                if (item.ItemID <= 0)
                {
                    throw new ArgumentException(
                        "Invalid item selected.");
                }

                if (item.QuantityRequested <= 0)
                {
                    throw new ArgumentException(
                        "Requested quantity must be greater than zero.");
                }
            }

            // Save the requisition using the logged-in user's ID.
            return repository.CreateRequisition(
                actor.UserID,
                requiredDate,
                justification,
                items);
        }



    }
}
