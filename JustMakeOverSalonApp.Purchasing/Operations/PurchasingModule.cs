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
    }
}