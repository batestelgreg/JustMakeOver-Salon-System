using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Text;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Settings.Repositories;

namespace JustMakeOverSalonApp.Settings.Services
{
    // Kani nga service kay nagdala sa business rules sa Settings module:
    // unit of measures master list, system preferences, ug Official Salon Email (SMTP).
    public sealed class SettingsService
    {
        private readonly SettingsRepository repository;
        private readonly EmailSettingsRepository emailRepository;

        public SettingsService(SettingsRepository repository)
            : this(repository, new EmailSettingsRepository(new SqlConnectionFactory()))
        {
        }

        public SettingsService(
            SettingsRepository repository,
            EmailSettingsRepository emailRepository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
            this.emailRepository = emailRepository ??
                throw new ArgumentNullException(nameof(emailRepository));
        }

        // Kani nga method nagkuha sa unit of measures list. Ang view
        // kay open sa settings.manage ug sa mga user nga mo-create/
        // update sa items (ang listahan gigamit sa item form dropdown).
        public Task<Models.UoMsOverview> LoadUoMsAsync(CurrentUser actor)
        {
            if (!actor.HasPermission(PermissionCodes.SettingsManage) &&
                !actor.HasPermission(PermissionCodes.InventoryCreate) &&
                !actor.HasPermission(PermissionCodes.InventoryUpdate))
            {
                throw new BusinessException("You do not have permission to view the unit of measures.");
            }

            return Task.FromResult(repository.LoadUoMs(actor.UserID));
        }

        // Kani nga method nag-save sa unit of measure: uomID <= 0 = create,
        // otherwise update. Ang name ug status kay optional depende sa action.
        public Task<int> SaveUomAsync(CurrentUser actor, int uomID, string uomName, bool? isActive)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            var cleanName = string.IsNullOrWhiteSpace(uomName) ? null : uomName.Trim();
            if (cleanName != null && cleanName.Length > 20)
            {
                throw new BusinessException("The unit of measure name must be 20 characters or fewer.");
            }

            if (uomID <= 0 && cleanName == null)
            {
                throw new BusinessException("The unit of measure name is required.");
            }

            var savedID = repository.SaveUom(actor.UserID,
                uomID > 0 ? uomID : (int?)null, cleanName, isActive);

            return Task.FromResult(savedID);
        }

        // Kani nga method nagkuha sa system preferences (non-sensitive:
        // branding ug default restock days - bisan kinsa nga active user
        // kay mo-access kay ang branding gigamit sa sidebar sa tanan).
        public Task<Models.PreferencesData> LoadPreferencesAsync(CurrentUser actor)
        {
            return Task.FromResult(repository.LoadPreferences(actor.UserID));
        }

        // Kani nga method nag-save sa system preferences (settings.manage).
        public Task SavePreferencesAsync(
            CurrentUser actor, string salonName, string salonTagline, int defaultRestockDays)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            if (string.IsNullOrWhiteSpace(salonName) || string.IsNullOrWhiteSpace(salonTagline))
            {
                throw new BusinessException("The salon name and tagline are required.");
            }

            if (defaultRestockDays < 1 || defaultRestockDays > 365)
            {
                throw new BusinessException("The default restock days must be between 1 and 365.");
            }

            repository.SavePreferences(
                actor.UserID, salonName.Trim(), salonTagline.Trim(), defaultRestockDays);

            return Task.CompletedTask;
        }

        // Returns non-secret summary of Official Salon Email (SMTP) settings for Admin UI.
        public Task<EmailSettingsSummary> LoadEmailSettingsAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);
            return Task.FromResult(emailRepository.GetAdminEmailSettings(actor.UserID));
        }

        // Saves Official Salon Email (SMTP) settings with DPAPI-encrypted App Password.
        public Task<EmailSettingsSummary> SaveEmailSettingsAsync(
            CurrentUser actor,
            string senderEmail,
            string senderName,
            string appPassword,
            string smtpHost,
            int smtpPort,
            bool useStartTls)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            var updated = emailRepository.SaveAdminEmailSettings(
                actor.UserID,
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort,
                useStartTls);

            return Task.FromResult(updated);
        }

        // Sends a live SMTP verification email using the Official Salon Email config.
        public async Task<Dictionary<string, object>> SendTestEmailAsync(
            CurrentUser actor,
            string testRecipientEmail,
            string senderEmail,
            string senderName,
            string appPassword,
            string smtpHost,
            int smtpPort,
            bool? useStartTls)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            SmtpRuntimeConfig config = emailRepository.ResolveTestConfig(
                actor.UserID,
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort,
                useStartTls);

            string recipient = string.IsNullOrWhiteSpace(testRecipientEmail)
                ? config.SenderEmail
                : testRecipientEmail.Trim();

            if (!EmailSettingsRepository.IsValidEmailFormat(recipient))
            {
                throw new BusinessException("Please enter a valid test recipient email address.");
            }

            string subject = string.Format(
                CultureInfo.InvariantCulture,
                "SMTP Test Email — {0}",
                config.SenderName);

            var html = new StringBuilder(1536);
            html.Append("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head>");
            html.Append("<body style=\"margin:0;padding:24px;background-color:#f4f6f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#182538;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:560px;margin:0 auto;background-color:#ffffff;border:1px solid #dce3ec;border-radius:10px;overflow:hidden;\">");
            html.Append("<tr><td style=\"background-color:#132436;padding:20px 24px;color:#ffffff;\">");
            html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
            EmailSettingsRepository.AppendBrandLogoCell(html, config.LogoUrl, config.SenderName, 48);
            html.Append("<td style=\"vertical-align:middle;\">");
            html.Append("<div style=\"font-size:18px;font-weight:700;\">").Append(WebUtility.HtmlEncode(config.SenderName)).Append("</div>");
            html.Append("<div style=\"font-size:12px;color:#c7d4e2;margin-top:2px;\">Official Salon Email Verification</div>");
            html.Append("</td></tr></table></td></tr>");
            html.Append("<tr><td style=\"padding:22px 24px;font-size:14px;line-height:1.6;color:#394b61;\">");
            html.Append("<p style=\"margin:0 0 12px;\">This test email confirms that your Official Salon Email (SMTP) configuration is working properly.</p>");
            html.Append("<p style=\"margin:0;font-size:13px;color:#526477;\"><strong>Official Sender:</strong> ")
                .Append(WebUtility.HtmlEncode(config.SenderName))
                .Append(" &lt;").Append(WebUtility.HtmlEncode(config.SenderEmail)).Append("&gt;<br/>")
                .Append("<strong>SMTP Server:</strong> ").Append(WebUtility.HtmlEncode(config.Host)).Append(":").Append(config.Port)
                .Append(config.UseStartTls ? " (STARTTLS)" : "")
                .Append("<br/><strong>Tested By:</strong> ").Append(WebUtility.HtmlEncode(actor.FullName ?? "Administrator"))
                .Append("</p>");
            html.Append("</td></tr></table></body></html>");

            string text = string.Format(
                CultureInfo.InvariantCulture,
                "{0}\n\nThis test email confirms that your Official Salon Email (SMTP) configuration is working properly.\nOfficial Sender: {1} <{2}>\nSMTP Server: {3}:{4}\nTested By: {5}",
                config.SenderName,
                config.SenderName,
                config.SenderEmail,
                config.Host,
                config.Port,
                actor.FullName ?? "Administrator");

            await EmailSettingsRepository.DispatchEmailAsync(
                config,
                recipient,
                config.SenderName,
                subject,
                html.ToString(),
                text).ConfigureAwait(false);

            return new Dictionary<string, object>
            {
                ["senderEmail"] = config.SenderEmail,
                ["recipientEmail"] = recipient,
                ["message"] = string.Format(
                    CultureInfo.InvariantCulture,
                    "Test email sent to {0} from {1}.",
                    recipient,
                    config.SenderEmail)
            };
        }
    }
}
