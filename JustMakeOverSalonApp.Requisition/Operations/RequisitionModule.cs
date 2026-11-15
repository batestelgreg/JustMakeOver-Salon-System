
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Requisition.Models;

namespace JustMakeOverSalonApp.Requisition.Operations
{
    // This class registers all bridge operations sa Requisition module.
    // Dinhi moagi ang requests from the frontend before reaching the service.
    // Requisition developer ra ang mo-manage ani nga file.
    public sealed class RequisitionModule : IModuleOperations
    {
        // Context is used to access the logged-in user and send responses.
        private IOperationContext context;

        // Service handles the business rules and validation.
        private Services.RequisitionService service;

        // FUNCTION 1: RegisterOperations
        // Register all Requisition operations para ma-recognize sila by the bridge.
        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Store the context so all handlers can use it.
            this.context = context;

            // Create the service and repository needed for database operations.
            this.service = new Services.RequisitionService(
                new Repositories.RequisitionRepository(new SqlConnectionFactory()));

            // Register the operations nga pwede tawagon sa frontend.
            registry.Register("LoadActiveItems", HandleLoadActiveItems);
            registry.Register("CreateRequisition", HandleCreateRequisition);
            registry.Register("LoadRequisitionHistory", HandleLoadRequisitionHistory);
            registry.Register("CancelRequisition", HandleCancelRequisition);
        }

        /* Kani nga block kay example ra sa handler pattern:
        private async Task HandleRequisitionListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */

        // FUNCTION 2: HandleLoadActiveItems
        // Handles the frontend request to get all active items.
        private Task HandleLoadActiveItems(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                // Get the currently logged-in user.
                var actor = context.RequireUser();

                // Call the service to retrieve active items.
                var items = service.LoadActiveItems(actor);

                // Send the retrieved items back to the frontend.
                context.SendResponse(requestID, true, new { items }, null);
            }
            catch (Exception ex)
            {
                // If an error occurs, send the error message to the frontend.
                context.SendResponse(requestID, false, null, ex.Message);
            }

            // Return a completed task because this handler has no async operation.
            return Task.CompletedTask;
        }

        // FUNCTION 3: HandleCreateRequisition
        // Handles the frontend request to create and save a new requisition.
        private Task HandleCreateRequisition(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                // Get the currently logged-in user.
                var actor = context.RequireUser();

                // Get the required date and justification sent by the frontend.
                string requiredDateText =
                    context.GetValueAsString(payload, "requiredDate");

                string justification =
                    context.GetValueAsString(payload, "justification");

                // Get the selected item IDs and their requested quantities.
                var itemIDs =
                    context.GetValueAsStringList(payload, "itemIDs");

                var quantities =
                    context.GetValueAsStringList(payload, "quantities");

                // Check if at least one item is selected and both lists match.
                if (itemIDs.Count == 0 || itemIDs.Count != quantities.Count)
                {
                    throw new ArgumentException(
                        "Invalid selected items or quantities.");
                }

                // Convert the required date from string to DateTime.
                DateTime requiredDate;

                if (!DateTime.TryParse(requiredDateText, out requiredDate))
                {
                    throw new ArgumentException(
                        "Please provide a valid required date.");
                }

                // Create a list that will contain the selected item details.
                var items = new List<RequisitionDetailModel>();

                // Loop through the selected items and their quantities.
                for (int i = 0; i < itemIDs.Count; i++)
                {
                    int itemID;
                    int quantity;

                    // Convert the item ID and quantity from string to integer.
                    // If either value is invalid, return an error.
                    if (!int.TryParse(itemIDs[i], out itemID)
                        || !int.TryParse(quantities[i], out quantity))
                    {
                        throw new ArgumentException(
                            "Invalid item ID or quantity.");
                    }

                    // Add the converted item information to the list.
                    items.Add(new RequisitionDetailModel
                    {
                        ItemID = itemID,
                        QuantityRequested = quantity
                    });
                }

                // Send the requisition details to the service for validation and saving.
                int requisitionID = service.CreateRequisition(
                    actor,
                    requiredDate,
                    justification,
                    items);

                // Send a successful response with the new Requisition ID.
                context.SendResponse(
                    requestID,
                    true,
                    new { requisitionID },
                    null);
            }
            catch (Exception ex)
            {
                // If something goes wrong, send the error message to the frontend.
                context.SendResponse(
                    requestID,
                    false,
                    null,
                    ex.Message);
            }

            // Return a completed task because this handler has no async operation.
            return Task.CompletedTask;
        }

        // FUNCTION 4: HandleLoadRequisitionHistory
        // Handles the frontend request to retrieve the user's requisition history.
        private Task HandleLoadRequisitionHistory(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                // Get the currently logged-in user.
                var actor = context.RequireUser();

                // Call the service to get this user's requisition history.
                var requisitions = service.LoadRequisitionHistory(actor);

                // Send the requisition history back to the frontend.
                context.SendResponse(
                    requestID,
                    true,
                    new { requisitions },
                    null);
            }
            catch (Exception ex)
            {
                // If an error occurs, send the error message to the frontend.
                context.SendResponse(
                    requestID,
                    false,
                    null,
                    ex.Message);
            }

            // Return a completed task because this handler has no async operation.
            return Task.CompletedTask;
        }


        // FUNCTION 5: HandleCancelRequisition
        // Handles the frontend request to cancel an existing requisition.
        private Task HandleCancelRequisition(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                // Get the currently logged-in user.
                var actor = context.RequireUser();

                // Get the requisition ID and cancellation reason from the frontend.
                string requisitionIDText =
                    context.GetValueAsString(payload, "requisitionID");

                string reason =
                    context.GetValueAsString(payload, "reason");

                // Convert the requisition ID from string to integer.
                int requisitionID;

                if (!int.TryParse(requisitionIDText, out requisitionID))
                {
                    throw new ArgumentException(
                        "Invalid requisition selected.");
                }

                // Call the service to validate and cancel the requisition.
                service.CancelRequisition(
                    actor,
                    requisitionID,
                    reason);

                // Send a successful response back to the frontend.
                context.SendResponse(
                    requestID,
                    true,
                    new { requisitionID },
                    null);
            }
            catch (Exception ex)
            {
                // If cancellation fails, send the error message to the frontend.
                context.SendResponse(
                    requestID,
                    false,
                    null,
                    ex.Message);
            }

            // Return a completed task because this handler has no async operation.
            return Task.CompletedTask;
        }

    }
}
