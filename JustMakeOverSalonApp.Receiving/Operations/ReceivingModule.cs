using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Receiving.Operations
{
    // Kani nga class kay nag-register sa tanang bridge operations sa Receiving module.
    // Kini nga file kay iya ra sa Receiving developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class ReceivingModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.ReceivingService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.ReceivingService(
                new Repositories.ReceivingRepository(new SqlConnectionFactory()));

            // Kani mga operation names kay ang bridge contract sa Receiving page.
            registry.Register("ReceivingOverview", HandleReceivingOverviewAsync);
            registry.Register("ReceivingSubmit", HandleReceivingSubmitAsync);
        }

        // Kani nga handler nagdala sa TANANG page data sa usa ra ka response
        // (pending queue + history) aron usa ra ka bridge call ang page load.
        private async Task HandleReceivingOverviewAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadOverviewAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong ano-on ang names diri).
            context.SendResponse(requestID, true, new
            {
                pending = overview.Pending,
                history = overview.History,
                items = overview.Items
            }, null);
        }

        // Kani nga handler nag-submit sa usa ka receipt.
        private async Task HandleReceivingSubmitAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.SubmitAsync(
                actor,
                context.GetValueAsInt(payload, "itemID"),
                context.GetValueAsInt(payload, "quantityReceived"),
                ParseOptionalID(context.GetValueAsString(payload, "repFID")),
                context.GetValueAsString(payload, "remarks"));

            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga helper kay mo-convert sa repFID string ngadto sa nullable int
        // (empty o 0 = walay RepF nga gi-receivean).
        private static int? ParseOptionalID(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || !int.TryParse(value, out int parsed) || parsed <= 0)
            {
                return null;
            }

            return parsed;
        }
    }
}
