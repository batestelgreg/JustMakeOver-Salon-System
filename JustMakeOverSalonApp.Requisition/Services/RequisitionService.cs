
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Requisition.Models;
using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Requisition.Services
{
    // This service handles the business rules sa Requisition module.
    // Dinhi ginacheck ang user permissions and validates user inputs.
    // The repository is called when database operations are needed.
    public sealed class RequisitionService
    {
        // Reference sa repository nga responsible for database operations.
        private readonly Repositories.RequisitionRepository repository;

        // Constructor: receives the repository nga gamiton ani nga service.
        public RequisitionService(Repositories.RequisitionRepository repository)
        {
            // Check kung naa ba tay valid repository before using it.
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        /* Diri ibutang ang imong service methods. Pananglitan sa pattern:
        public Task LoadSomethingAsync(CurrentUser actor)
        {
            // Check the user's permission sa backend, dili lang sa frontend.
            actor.RequirePermission("<module>.view");

            return Task.Run(() =>
            {
                // Dinhi ibutang ang validation ug repository call.
                throw new BusinessException("This operation is not yet implemented.");
            });
        }
        */

        // FUNCTION 1: LoadActiveItems
        // Get all active items nga pwede pilion sa user for their requisition.
        public List<ItemRecord> LoadActiveItems(CurrentUser actor)
        {
            // Check if the user has permission to view requisitions.
            actor.RequirePermission("requisitions.view");

            // Call the repository to get active items from the database.
            return repository.GetActiveItems();
        }

        // FUNCTION 2: CreateRequisition
        // Handles the creation of a new requisition.
        // I-check sa una ang permissions and user inputs before saving.
        public int CreateRequisition(
            CurrentUser actor,
            DateTime requiredDate,
            string justification,
            List<RequisitionDetailModel> items)
        {
            // Check if the user has permission to create a requisition.
            actor.RequirePermission("requisitions.create");

            // Check if the required date is not earlier than today's date.
            if (requiredDate.Date < DateTime.Today)
            {
                throw new ArgumentException(
                    "Required date cannot be in the past.");
            }

            // Make sure nga naay justification ang user's request.
            if (string.IsNullOrWhiteSpace(justification))
            {
                throw new ArgumentException(
                    "Please provide a justification.");
            }

            // Check if the justification exceeds the 500-character limit.
            if (justification.Length > 500)
            {
                throw new ArgumentException(
                    "Justification cannot exceed 500 characters.");
            }

            // Make sure nga at least one item is selected.
            if (items == null || items.Count == 0)
            {
                throw new ArgumentException(
                    "Please select at least one item.");
            }

            // Loop through each selected item to validate its information.
            foreach (var item in items)
            {
                // Check if the selected Item ID is valid.
                if (item.ItemID <= 0)
                {
                    throw new ArgumentException(
                        "Invalid item selected.");
                }

                // Make sure nga ang requested quantity is greater than zero.
                if (item.QuantityRequested <= 0)
                {
                    throw new ArgumentException(
                        "Requested quantity must be greater than zero.");
                }
            }

            // If all inputs are valid, send the information to the repository.
            // Use the logged-in user's ID as the requestor.
            return repository.CreateRequisition(
                actor.UserID,
                requiredDate,
                justification,
                items);
        }

        // FUNCTION 3: LoadRequisitionHistory
        // Get the requisition history sa currently logged-in user.
        public List<RequisitionHistoryModel> LoadRequisitionHistory(CurrentUser actor)
        {
            // Check if the user has permission to view requisition history.
            actor.RequirePermission("requisitions.view");

            // Call the repository to retrieve only this user's requisitions.
            return repository.GetRequisitionHistory(actor.UserID);
        }


        // FUNCTION 4: LoadPendingRequisitions
        // Get all pending requests para makita sa Admin ug Manager
        // kung unsay ilang kinahanglan i-review.
        public List<RequisitionModel> LoadPendingRequisitions(CurrentUser actor)
        {
            // Make sure nga naa tay valid logged-in user.
            if (actor == null)
            {
                throw new ArgumentException(
                    "Invalid user session.");
            }

            // Only users with approval permission can view this list.
            actor.RequirePermission("requisitions.approve");

            // Get all pending requisitions from the repository.
            return repository.GetPendingRequisitions();
        }


        // FUNCTION 6: LoadAllRequisitionHistory
        // Get all approved and rejected requisitions para sa Admin ug Manager.
        public List<RequisitionModel> LoadAllRequisitionHistory(CurrentUser actor)
        {
            // Make sure nga naa tay valid logged-in user.
            if (actor == null)
            {
                throw new ArgumentException(
                    "Invalid user session.");
            }

            // Only users with approval permission can view this history.
            actor.RequirePermission("requisitions.approve");

            // Get all approved and rejected requisitions.
            return repository.GetAllApprovedRejectedRequisitions();
        }


        // FUNCTION 4: CancelRequisition
        // Handles the cancellation of an existing requisition.
        // Ang SQL procedure na ang mo-check kung authorized ang user.
        public void CancelRequisition(
            CurrentUser actor,
            int requisitionID,
            string reason)
        {
            // Make sure nga naa tay valid logged-in user.
            if (actor == null)
            {
                throw new ArgumentException(
                    "Invalid user session.");
            }

            // Check if the requisition ID is valid.
            if (requisitionID <= 0)
            {
                throw new ArgumentException(
                    "Invalid requisition selected.");
            }

            // Check if the cancellation reason exceeds 500 characters.
            if (reason != null && reason.Length > 500)
            {
                throw new ArgumentException(
                    "Cancellation reason cannot exceed 500 characters.");
            }

            // Call the repository using the logged-in user's ID.
            // The stored procedure handles the authorization and cancellation.
            repository.CancelRequisition(
                requisitionID,
                actor.UserID,
                reason);
        }


        // FUNCTION 5: ApproveRequisition
        // Check permission before approving the requisition.
        // The SQL procedure handles inventory reservation.
        public void ApproveRequisition(
            CurrentUser actor,
            int requisitionID)
        {
            if (actor == null)
            {
                throw new ArgumentException(
                    "Invalid user session.");
            }

            // Only users with approval permission can approve.
            actor.RequirePermission("requisitions.approve");

            if (requisitionID <= 0)
            {
                throw new ArgumentException(
                    "Invalid requisition selected.");
            }

            repository.ApproveRequisition(
                requisitionID,
                actor.UserID);
        }

        // FUNCTION 6: RejectRequisition
        // Rejection reason is required para mahibaw-an sa requestor
        // nganong wala na-approve ang iyang request.
        public void RejectRequisition(
            CurrentUser actor,
            int requisitionID,
            string reason)
        {
            if (actor == null)
            {
                throw new ArgumentException(
                    "Invalid user session.");
            }

            // Only users with rejection permission can reject.
            actor.RequirePermission("requisitions.reject");

            if (requisitionID <= 0)
            {
                throw new ArgumentException(
                    "Invalid requisition selected.");
            }

            if (string.IsNullOrWhiteSpace(reason))
            {
                throw new ArgumentException(
                    "Rejection reason is required.");
            }

            if (reason.Length > 500)
            {
                throw new ArgumentException(
                    "Rejection reason cannot exceed 500 characters.");
            }

            repository.RejectRequisition(
                requisitionID,
                actor.UserID,
                reason.Trim());
        }

    }
}
