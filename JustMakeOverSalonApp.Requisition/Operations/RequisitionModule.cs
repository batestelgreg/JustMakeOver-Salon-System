using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Requisition.Models;

namespace JustMakeOverSalonApp.Requisition.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Requisition module.
    // Kini nga file kay iya ra sa Requisition developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class RequisitionModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.RequisitionService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.RequisitionService(
                new Repositories.RequisitionRepository(new SqlConnectionFactory()));



            // Kani nga linya kay pananglitan - i-uncomment ug i-adjust:
            // registry.Register("RequisitionList", HandleRequisitionListAsync);
            registry.Register("LoadActiveItems", HandleLoadActiveItems);
            registry.Register("CreateRequisition", HandleCreateRequisition);
        }

        /* Kani nga block kay pananglitan sa handler pattern:
        private async Task HandleRequisitionListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */

        // Handles the request to load active items.
        private Task HandleLoadActiveItems(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                var actor = context.RequireUser();

                var items = service.LoadActiveItems(actor);

                context.SendResponse(requestID, true, new { items }, null);
            }
            catch (Exception ex)
            {
                context.SendResponse(requestID, false, null, ex.Message);
            }

            return Task.CompletedTask;
        }


        // Handles the request to create a requisition.
        private Task HandleCreateRequisition(
            Dictionary<string, object> payload,
            string requestID)
        {
            try
            {
                var actor = context.RequireUser();

                // Get the requisition details from the frontend.
                string requiredDateText =
                    context.GetValueAsString(payload, "requiredDate");

                string justification =
                    context.GetValueAsString(payload, "justification");

                // Get the selected item IDs and quantities.
                var itemIDs =
                    context.GetValueAsStringList(payload, "itemIDs");

                var quantities =
                    context.GetValueAsStringList(payload, "quantities");

                // Make sure both lists have matching entries.
                if (itemIDs.Count == 0 || itemIDs.Count != quantities.Count)
                {
                    throw new ArgumentException(
                        "Invalid selected items or quantities.");
                }

                // Convert the required date.
                DateTime requiredDate;

                if (!DateTime.TryParse(requiredDateText, out requiredDate))
                {
                    throw new ArgumentException(
                        "Please provide a valid required date.");
                }

                // Prepare the selected items.
                var items = new List<RequisitionDetailModel>();

                for (int i = 0; i < itemIDs.Count; i++)
                {
                    int itemID;
                    int quantity;

                    if (!int.TryParse(itemIDs[i], out itemID)
                        || !int.TryParse(quantities[i], out quantity))
                    {
                        throw new ArgumentException(
                            "Invalid item ID or quantity.");
                    }

                    items.Add(new RequisitionDetailModel
                    {
                        ItemID = itemID,
                        QuantityRequested = quantity
                    });
                }

                // Save the requisition through the service.
                int requisitionID = service.CreateRequisition(
                    actor,
                    requiredDate,
                    justification,
                    items);

                context.SendResponse(
                    requestID,
                    true,
                    new { requisitionID },
                    null);
            }
            catch (Exception ex)
            {
                context.SendResponse(
                    requestID,
                    false,
                    null,
                    ex.Message);
            }

            return Task.CompletedTask;
        }

    }
}
