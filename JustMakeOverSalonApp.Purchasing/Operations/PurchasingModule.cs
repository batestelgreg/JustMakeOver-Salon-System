using System.Collections.Generic;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Purchasing.Repositories;
using JustMakeOverSalonApp.Purchasing.Services;

namespace JustMakeOverSalonApp.Purchasing.Operations
{
    // Registers the frontend-to-C# operations.
    public sealed class PurchasingModule : IModuleOperations
    {
        private IOperationContext context;
        private PurchasingService service;

        public void RegisterOperations(
            OperationRegistry registry,
            IOperationContext context)
        {
            this.context = context;

            service = new PurchasingService(
                new PurchasingRepository(new SqlConnectionFactory()));

            registry.Register(
                "PurchasingWorkspaceLoad", HandleLoadAsync);

            registry.Register(
                "PurchasingWorkspaceAction", HandleActionAsync);

            // Kani nga operations kay ON-DEMAND print calls. Wala ni
            // ma-apil sa page load, so one DB call gihapon ang page.
            registry.Register(
                "PurchasingPurchaseOrderPrint",
                HandlePurchaseOrderPrintAsync);

            registry.Register(
                "PurchasingReturnSlipPrint",
                HandleReturnSlipPrintAsync);
        }

        private async Task HandleLoadAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var result = await service.LoadAsync(context.RequireUser());
            context.SendResponse(requestID, true, result, null);
        }

        private async Task HandleActionAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            string action = context.GetValueAsString(payload, "action");

            // Serialize input values, never interpolate them into SQL.
            var serializer = new JavaScriptSerializer();
            string json = serializer.Serialize(payload);

            var result = await service.ExecuteAsync(
                context.RequireUser(), action, json);

            context.SendResponse(requestID, true, result, null);
        }

        // Kani nga handler nagkuha sa real PO print data on-demand.
        private async Task HandlePurchaseOrderPrintAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var order = await service.GetPurchaseOrderPrintAsync(
                context.RequireUser(),
                ParseID(context.GetValueAsString(payload, "poID")));

            context.SendResponse(requestID, true, new { order }, null);
        }

        // Kani nga handler nagkuha sa real Return Slip data on-demand.
        private async Task HandleReturnSlipPrintAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var slip = await service.GetReturnSlipPrintAsync(
                context.RequireUser(),
                ParseID(context.GetValueAsString(payload, "drID")));

            context.SendResponse(requestID, true, new { slip }, null);
        }

        // Kani nga helper kay para sa safe ID parsing (invalid = 0,
        // ug ang service mo-throw sa business message).
        private static int ParseID(string text)
        {
            int.TryParse(text, out int id);
            return id;
        }
    }
}