using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Suppliers.Operations
{
    // Kani nga class kay nag-register sa tanang bridge operations sa Suppliers module.
    // Kini nga file kay iya ra sa Suppliers developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class SuppliersModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.SuppliersService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.SuppliersService(
                new Repositories.SuppliersRepository(new SqlConnectionFactory()));

            // Kani mga operation names kay ang bridge contract sa Suppliers page.
            registry.Register("SuppliersList", HandleSuppliersListAsync);
            registry.Register("SuppliersSave", HandleSuppliersSaveAsync);
        }

        // Kani nga handler nagdala sa suppliers master list
        // (nga may quotation ug PO counts) sa usa ra ka response.
        private async Task HandleSuppliersListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadSuppliersAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong exact nga names diri).
            context.SendResponse(requestID, true, new
            {
                suppliers = overview.Suppliers
            }, null);
        }

        // Kani nga handler nag-save sa supplier: supplierID <= 0 = create,
        // otherwise update (fields o active status).
        private async Task HandleSuppliersSaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();

            var idText = context.GetValueAsString(payload, "supplierID");
            int.TryParse(idText, out int supplierID);

            var nameText = context.GetValueAsString(payload, "supplierName");
            var firstNameText = context.GetValueAsString(payload, "contactFirstName");
            var middleNameText = context.GetValueAsString(payload, "contactMiddleName");
            var lastNameText = context.GetValueAsString(payload, "contactLastName");
            var phoneText = context.GetValueAsString(payload, "phone");
            var emailText = context.GetValueAsString(payload, "email");
            var addressText = context.GetValueAsString(payload, "address");
            var isActiveText = context.GetValueAsString(payload, "isActive");
            bool? isActive = null;
            if (isActiveText == "true")
            {
                isActive = true;
            }
            else if (isActiveText == "false")
            {
                isActive = false;
            }

            var result = await service.SaveSupplierAsync(
                actor, supplierID, nameText,
                firstNameText, middleNameText, lastNameText,
                phoneText, emailText, addressText, isActive);

            if (result != null)
            {
                // Kani nga response kay para sa create path
                // (moyra makita sa frontend ang generated code).
                context.SendResponse(requestID, true, new
                {
                    supplierID = result.Item1,
                    supplierCode = result.Item2
                }, null);
            }
            else
            {
                context.SendResponse(requestID, true, null, null);
            }
        }
    }
}
