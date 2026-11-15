using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Settings.Operations
{
    // Kani nga class kay nag-register sa tanang bridge operations sa Settings module.
    // Kini nga file kay iya ra sa Settings developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class SettingsModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.SettingsService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.SettingsService(
                new Repositories.SettingsRepository(new SqlConnectionFactory()));

            // Kani mga operation names kay ang bridge contract sa Settings page.
            registry.Register("SettingsUoMs", HandleSettingsUoMsAsync);
            registry.Register("SettingsUomSave", HandleSettingsUomSaveAsync);
            registry.Register("SettingsPreferences", HandleSettingsPreferencesAsync);
            registry.Register("SettingsPreferencesSave", HandleSettingsPreferencesSaveAsync);
        }

        // Kani nga handler nagdala sa unit of measures master list
        // (nga may item count kada unit) sa usa ra ka response.
        private async Task HandleSettingsUoMsAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadUoMsAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong exact nga names diri).
            context.SendResponse(requestID, true, new
            {
                uoMs = overview.UoMs
            }, null);
        }

        // Kani nga handler nag-save sa unit of measure: uomID <= 0 = create,
        // otherwise update (name o active status).
        private async Task HandleSettingsUomSaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();

            var idText = context.GetValueAsString(payload, "uomID");
            int.TryParse(idText, out int uomID);

            var nameText = context.GetValueAsString(payload, "uomName");
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

            var savedID = await service.SaveUomAsync(actor, uomID, nameText, isActive);
            context.SendResponse(requestID, true, new { uomID = savedID }, null);
        }

        // Kani nga handler nagdala sa system preferences
        // (SalonName, SalonTagline, DefaultRestockDays).
        private async Task HandleSettingsPreferencesAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var preferences = await service.LoadPreferencesAsync(actor);
            context.SendResponse(requestID, true, new
            {
                salonName = preferences.SalonName,
                salonTagline = preferences.SalonTagline,
                defaultRestockDays = preferences.DefaultRestockDays
            }, null);
        }

        // Kani nga handler nag-save sa system preferences.
        private async Task HandleSettingsPreferencesSaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();

            var salonName = context.GetValueAsString(payload, "salonName");
            var salonTagline = context.GetValueAsString(payload, "salonTagline");
            int.TryParse(context.GetValueAsString(payload, "defaultRestockDays"), out int defaultRestockDays);

            await service.SavePreferencesAsync(actor, salonName, salonTagline, defaultRestockDays);
            context.SendResponse(requestID, true, null, null);
        }
    }
}
