using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Delivery.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Delivery module.
    // Kini nga file kay iya ra sa Delivery developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class DeliveryModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.DeliveryService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.DeliveryService(
                new Repositories.DeliveryRepository(new SqlConnectionFactory()));

            // Kani mga operation names kay ang bridge contract sa Delivery page.
            registry.Register("DeliveryList", HandleDeliveryListAsync);
            registry.Register("DeliveryGenerate", HandleDeliveryGenerateAsync);
            registry.Register("DeliveryMarkIssued", HandleDeliveryMarkIssuedAsync);
            registry.Register("DeliveryNoteDiscrepancy", HandleDeliveryNoteDiscrepancyAsync);
            registry.Register("DeliveryComplete", HandleDeliveryCompleteAsync);
            registry.Register("DeliveryReissue", HandleDeliveryReissueAsync);
        }

        // Kani nga handler nagdala sa TANANG page data sa usa ra ka response
        // (allocated requisitions + AR records).
        private async Task HandleDeliveryListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadOverviewAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong exact nga names diri).
            context.SendResponse(requestID, true, new
            {
                allocated = overview.Allocated,
                deliveries = overview.Deliveries
            }, null);
        }

        // Kani nga handler nag-generate sa AR para sa usa ka requisition.
        private async Task HandleDeliveryGenerateAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var requisitionID = ParseID(context.GetValueAsString(payload, "requisitionID"));

            var result = await service.GenerateARAsync(actor, requisitionID);

            context.SendResponse(requestID, true, new
            {
                deliveryID = result?.Item1 ?? 0,
                arCode = result?.Item2 ?? string.Empty
            }, null);
        }

        // Kani nga handler nag-mark issued sa AR (issue to department).
        private async Task HandleDeliveryMarkIssuedAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var deliveryID = ParseID(context.GetValueAsString(payload, "deliveryID"));

            await service.MarkIssuedAsync(actor, deliveryID);
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler nag-note discrepancy sa AR.
        private async Task HandleDeliveryNoteDiscrepancyAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var deliveryID = ParseID(context.GetValueAsString(payload, "deliveryID"));
            var notes = context.GetValueAsString(payload, "notes");

            await service.NoteDiscrepancyAsync(actor, deliveryID, notes);
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler nag-complete sa AR: e-sign + deduction +
        // requisition Fulfilled + requester notification.
        private async Task HandleDeliveryCompleteAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var deliveryID = ParseID(context.GetValueAsString(payload, "deliveryID"));
            var signature = context.GetValueAsString(payload, "signature");

            await service.CompleteAsync(actor, deliveryID, signature);
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler nag-reissue sa AR human ma-correct ang
        // discrepancy (balik sa 'Generated').
        private async Task HandleDeliveryReissueAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var deliveryID = ParseID(context.GetValueAsString(payload, "deliveryID"));

            await service.ReissueAsync(actor, deliveryID);
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga helper kay para sa safe ID parsing (empty o invalid = 0,
        // ug ang service mo-throw sa business message).
        private static int ParseID(string text)
        {
            int.TryParse(text, out int id);
            return id;
        }
    }
}
