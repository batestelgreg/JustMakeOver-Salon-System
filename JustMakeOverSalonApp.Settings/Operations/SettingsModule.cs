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
            var connectionFactory = new SqlConnectionFactory();
            this.context = context;
            this.service = new Services.SettingsService(
                new Repositories.SettingsRepository(connectionFactory),
                new EmailSettingsRepository(connectionFactory));

            // Kani mga operation names kay ang bridge contract sa Settings page.
            registry.Register("SettingsUoMs", HandleSettingsUoMsAsync);
            registry.Register("SettingsUomSave", HandleSettingsUomSaveAsync);
            registry.Register("SettingsPreferences", HandleSettingsPreferencesAsync);
            registry.Register("SettingsPreferencesSave", HandleSettingsPreferencesSaveAsync);
            registry.Register("SettingsEmailGet", HandleSettingsEmailGetAsync);
            registry.Register("SettingsEmailSave", HandleSettingsEmailSaveAsync);
            registry.Register("SettingsEmailTest", HandleSettingsEmailTestAsync);
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

        // Returns Official Salon Email configuration summary (never includes password).
        private async Task HandleSettingsEmailGetAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var summary = await service.LoadEmailSettingsAsync(actor);
            context.SendResponse(requestID, true, ToEmailResponse(summary), null);
        }

        // Saves Official Salon Email SMTP configuration into dbo.EMAIL_SETTINGS (DPAPI-encrypted).
        private async Task HandleSettingsEmailSaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();

            var senderEmail = context.GetValueAsString(payload, "senderEmail");
            var senderName = context.GetValueAsString(payload, "senderName");
            var appPassword = context.GetValueAsString(payload, "appPassword");
            var smtpHost = context.GetValueAsString(payload, "smtpHost");
            int.TryParse(context.GetValueAsString(payload, "smtpPort"), out int smtpPort);
            var startTlsText = context.GetValueAsString(payload, "useStartTls");
            bool useStartTls = !string.Equals(startTlsText, "false", System.StringComparison.OrdinalIgnoreCase);

            var updated = await service.SaveEmailSettingsAsync(
                actor,
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort,
                useStartTls);

            context.SendResponse(requestID, true, ToEmailResponse(updated), null);
        }

        // Sends a test verification email using Official Salon Email SMTP settings.
        private async Task HandleSettingsEmailTestAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();

            var testRecipient = context.GetValueAsString(payload, "testRecipientEmail");
            var senderEmail = context.GetValueAsString(payload, "senderEmail");
            var senderName = context.GetValueAsString(payload, "senderName");
            var appPassword = context.GetValueAsString(payload, "appPassword");
            var smtpHost = context.GetValueAsString(payload, "smtpHost");
            int.TryParse(context.GetValueAsString(payload, "smtpPort"), out int smtpPort);
            var startTlsText = context.GetValueAsString(payload, "useStartTls");
            bool? useStartTls = null;
            if (string.Equals(startTlsText, "true", System.StringComparison.OrdinalIgnoreCase))
            {
                useStartTls = true;
            }
            else if (string.Equals(startTlsText, "false", System.StringComparison.OrdinalIgnoreCase))
            {
                useStartTls = false;
            }

            var result = await service.SendTestEmailAsync(
                actor,
                testRecipient,
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort,
                useStartTls);

            context.SendResponse(requestID, true, result, null);
        }

        private static object ToEmailResponse(JustMakeOverSalonApp.Core.Models.EmailSettingsSummary summary)
        {
            return new
            {
                senderEmail = summary.SenderEmail ?? string.Empty,
                senderName = summary.SenderName ?? string.Empty,
                smtpHost = summary.SmtpHost ?? EmailSettingsRepository.DefaultSmtpHost,
                smtpPort = summary.SmtpPort > 0 ? summary.SmtpPort : EmailSettingsRepository.DefaultSmtpPort,
                useStartTls = summary.UseStartTls,
                hasPassword = summary.HasPassword,
                isConfigured = summary.IsConfigured,
                updatedAt = summary.UpdatedAt,
                updatedByName = summary.UpdatedByName ?? string.Empty
            };
        }
    }
}
