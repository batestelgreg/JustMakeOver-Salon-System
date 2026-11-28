using System;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Security;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Data
{
    // Shared repository and helper for Official Salon Email (SMTP) configuration.
    // Resolves Admin-managed credentials stored in dbo.EMAIL_SETTINGS (encrypted via DPAPI),
    // with non-secret transport/template defaults read from App.config.
    public sealed class EmailSettingsRepository
    {
        public const string DefaultSmtpHost = "smtp.gmail.com";
        public const int DefaultSmtpPort = 587;
        public const string DefaultSenderName = "Just MakeOver Beauty Salon & Spa";
        public const string DefaultLogoUrl =
            "https://raw.githubusercontent.com/batestelgreg/JustMakeOverSalonSystem-App/main/JustMakeOverSalonApp/Frontend/images/logo.png";
        public const string DefaultPaymentTerms = "Net 30 Days upon delivery and inspection";

        private static SmtpSendDelegate registeredTransport;

        private readonly ISqlConnectionFactory connectionFactory;

        public EmailSettingsRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory
                ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        public static void RegisterTransport(SmtpSendDelegate transport)
        {
            registeredTransport = transport ?? throw new ArgumentNullException(nameof(transport));
        }

        public static Task DispatchEmailAsync(
            SmtpRuntimeConfig config,
            string recipientEmail,
            string recipientName,
            string subject,
            string htmlBody,
            string textBody,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (registeredTransport == null)
            {
                throw new InvalidOperationException(
                    "No SMTP transport has been registered for sending emails.");
            }

            return registeredTransport(
                config,
                recipientEmail,
                recipientName,
                subject,
                htmlBody,
                textBody,
                cancellationToken);
        }

        public EmailSettingsSummary GetAdminEmailSettings(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Settings_GetEmailSettings", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return CreateEmptySummary();
                    }

                    return ReadSummaryRow(reader);
                }
            }
        }

        public EmailSettingsSummary SaveAdminEmailSettings(
            int actorUserID,
            string senderEmail,
            string senderName,
            string plainAppPassword,
            string smtpHost,
            int smtpPort,
            bool useStartTls)
        {
            string cleanEmail = (senderEmail ?? string.Empty).Trim();
            string cleanName = string.IsNullOrWhiteSpace(senderName)
                ? DefaultSenderName
                : senderName.Trim();
            string cleanHost = string.IsNullOrWhiteSpace(smtpHost)
                ? DefaultSmtpHost
                : smtpHost.Trim();
            int validPort = smtpPort > 0 && smtpPort <= 65535 ? smtpPort : DefaultSmtpPort;

            if (!IsValidEmailFormat(cleanEmail))
            {
                throw new BusinessException("Please enter a valid Official Salon Email address.");
            }

            string normalizedSecret = SmtpSecretProtector.NormalizeAppPassword(plainAppPassword);
            string encryptedSecret = string.IsNullOrEmpty(normalizedSecret)
                ? null
                : SmtpSecretProtector.Protect(normalizedSecret);

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Settings_SaveEmailSettings", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@SenderEmail", SqlDbType.NVarChar, 255).Value = cleanEmail;
                command.Parameters.Add("@SenderName", SqlDbType.NVarChar, 120).Value = cleanName;
                command.Parameters.Add("@EncryptedAppPassword", SqlDbType.NVarChar, -1).Value =
                    string.IsNullOrEmpty(encryptedSecret) ? (object)DBNull.Value : encryptedSecret;
                command.Parameters.Add("@SmtpHost", SqlDbType.NVarChar, 150).Value = cleanHost;
                command.Parameters.Add("@SmtpPort", SqlDbType.Int).Value = validPort;
                command.Parameters.Add("@UseStartTls", SqlDbType.Bit).Value = useStartTls;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return CreateEmptySummary();
                    }

                    return ReadSummaryRow(reader);
                }
            }
        }

        // Resolves runtime SMTP settings strictly from Admin-configured dbo.EMAIL_SETTINGS.
        public SmtpRuntimeConfig ResolveRuntimeConfig(
            int actorUserID,
            string fallbackSenderName = DefaultSenderName)
        {
            var appDefaults = ReadAppConfigDefaults(fallbackSenderName);
            var dbRow = ReadDbRuntimeRow(actorUserID);

            if (dbRow == null
                || string.IsNullOrWhiteSpace(dbRow.SenderEmail)
                || string.IsNullOrWhiteSpace(dbRow.EncryptedPassword))
            {
                throw new BusinessException(
                    "Official Salon Email (SMTP) is not configured yet. Ask an Administrator to set the Salon Email and Google App Password under Settings -> Official Salon Email.");
            }

            if (!IsValidEmailFormat(dbRow.SenderEmail))
            {
                throw new BusinessException(
                    "The Official Salon Email configured in Settings is not valid. Ask an Administrator to update it.");
            }

            string decrypted = SmtpSecretProtector.Unprotect(dbRow.EncryptedPassword);
            if (string.IsNullOrWhiteSpace(decrypted))
            {
                throw new BusinessException(
                    "Official Salon Email (SMTP) App Password is empty. Ask an Administrator to re-enter it under Settings -> Official Salon Email.");
            }

            return new SmtpRuntimeConfig
            {
                Host = string.IsNullOrWhiteSpace(dbRow.Host) ? appDefaults.Host : dbRow.Host,
                Port = dbRow.Port > 0 && dbRow.Port <= 65535 ? dbRow.Port : appDefaults.Port,
                UseStartTls = dbRow.UseStartTls,
                SenderEmail = dbRow.SenderEmail.Trim(),
                SenderName = string.IsNullOrWhiteSpace(dbRow.SenderName)
                    ? appDefaults.SenderName
                    : dbRow.SenderName.Trim(),
                AppPassword = decrypted,
                LogoUrl = appDefaults.LogoUrl,
                PaymentTerms = appDefaults.PaymentTerms,
                TimeoutMs = appDefaults.TimeoutMs,
                Source = "Database"
            };
        }

        // Resolves an editable test configuration (used by Settings "Send Test Email"),
        // allowing Admin to test unsaved edits while keeping saved password if blank.
        public SmtpRuntimeConfig ResolveTestConfig(
            int actorUserID,
            string senderEmailOverride,
            string senderNameOverride,
            string plainPasswordOverride,
            string smtpHostOverride,
            int smtpPortOverride,
            bool? useStartTlsOverride)
        {
            var appDefaults = ReadAppConfigDefaults(DefaultSenderName);
            var dbRow = ReadDbRuntimeRow(actorUserID);

            string senderEmail = !string.IsNullOrWhiteSpace(senderEmailOverride)
                ? senderEmailOverride.Trim()
                : (dbRow != null && !string.IsNullOrWhiteSpace(dbRow.SenderEmail)
                    ? dbRow.SenderEmail.Trim()
                    : string.Empty);

            string senderName = !string.IsNullOrWhiteSpace(senderNameOverride)
                ? senderNameOverride.Trim()
                : (dbRow != null && !string.IsNullOrWhiteSpace(dbRow.SenderName)
                    ? dbRow.SenderName.Trim()
                    : appDefaults.SenderName);

            string host = !string.IsNullOrWhiteSpace(smtpHostOverride)
                ? smtpHostOverride.Trim()
                : (dbRow != null && !string.IsNullOrWhiteSpace(dbRow.Host)
                    ? dbRow.Host.Trim()
                    : appDefaults.Host);

            int port = smtpPortOverride > 0 && smtpPortOverride <= 65535
                ? smtpPortOverride
                : (dbRow != null && dbRow.Port > 0 && dbRow.Port <= 65535
                    ? dbRow.Port
                    : appDefaults.Port);

            bool useStartTls = useStartTlsOverride ?? (dbRow != null ? dbRow.UseStartTls : appDefaults.UseStartTls);

            string appPassword = SmtpSecretProtector.NormalizeAppPassword(plainPasswordOverride);
            if (string.IsNullOrEmpty(appPassword)
                && dbRow != null
                && !string.IsNullOrWhiteSpace(dbRow.EncryptedPassword))
            {
                appPassword = SmtpSecretProtector.Unprotect(dbRow.EncryptedPassword);
            }

            if (!IsValidEmailFormat(senderEmail))
            {
                throw new BusinessException("Please enter a valid Official Salon Email address before sending a test email.");
            }

            if (string.IsNullOrWhiteSpace(appPassword))
            {
                throw new BusinessException("Please enter the 16-character Google App Password before sending a test email.");
            }

            return new SmtpRuntimeConfig
            {
                Host = string.IsNullOrWhiteSpace(host) ? DefaultSmtpHost : host,
                Port = port,
                UseStartTls = useStartTls,
                SenderEmail = senderEmail,
                SenderName = string.IsNullOrWhiteSpace(senderName) ? DefaultSenderName : senderName,
                AppPassword = appPassword,
                LogoUrl = appDefaults.LogoUrl,
                PaymentTerms = appDefaults.PaymentTerms,
                TimeoutMs = appDefaults.TimeoutMs,
                Source = "SettingsTest"
            };
        }

        public static bool IsValidEmailFormat(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                return false;
            }

            string trimmed = raw.Trim();
            if (trimmed.Contains(" "))
            {
                return false;
            }

            int at = trimmed.IndexOf('@');
            if (at <= 0 || at >= trimmed.Length - 1)
            {
                return false;
            }

            // Disallow multiple '@' symbols.
            if (trimmed.IndexOf('@', at + 1) >= 0)
            {
                return false;
            }

            string domain = trimmed.Substring(at + 1);
            if (!domain.Contains(".")
                || domain.StartsWith(".", StringComparison.Ordinal)
                || domain.EndsWith(".", StringComparison.Ordinal)
                || domain.Contains(".."))
            {
                return false;
            }

            return true;
        }

        // Renders the salon logo via a hosted HTTPS URL (zero MIME image attachments)
        // with a pure HTML gold-outlined JM emblem fallback if LogoUrl is unavailable.
        public static void AppendBrandLogoCell(
            StringBuilder html,
            string logoUrl,
            string salonName,
            int sizePx)
        {
            if (!string.IsNullOrWhiteSpace(logoUrl)
                && Uri.TryCreate(logoUrl, UriKind.Absolute, out Uri parsed)
                && (parsed.Scheme == Uri.UriSchemeHttps || parsed.Scheme == Uri.UriSchemeHttp))
            {
                html.Append("<td style=\"padding-right:14px;vertical-align:middle;\">");
                html.Append("<img src=\"").Append(WebUtility.HtmlEncode(logoUrl))
                    .Append("\" alt=\"").Append(WebUtility.HtmlEncode(salonName ?? DefaultSenderName))
                    .Append("\" width=\"").Append(sizePx)
                    .Append("\" height=\"").Append(sizePx)
                    .Append("\" style=\"display:block;width:").Append(sizePx)
                    .Append("px;height:").Append(sizePx)
                    .Append("px;border-radius:50%;border:2px solid #f2a832;box-sizing:border-box;\" />");
                html.Append("</td>");
                return;
            }

            int fontSize = sizePx >= 50 ? 20 : 18;
            int innerLineHeight = sizePx - 4;

            html.Append("<td style=\"padding-right:14px;vertical-align:middle;\">");
            html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" width=\"")
                .Append(sizePx)
                .Append("\" height=\"")
                .Append(sizePx)
                .Append("\" style=\"width:")
                .Append(sizePx)
                .Append("px;height:")
                .Append(sizePx)
                .Append("px;border-radius:50%;border:2px solid #f2a832;background-color:#0d1b2a;border-collapse:separate;\"><tr>");
            html.Append("<td align=\"center\" valign=\"middle\" style=\"width:")
                .Append(sizePx)
                .Append("px;height:")
                .Append(innerLineHeight)
                .Append("px;text-align:center;vertical-align:middle;font-family:Georgia,'Times New Roman',serif;font-size:")
                .Append(fontSize)
                .Append("px;font-weight:700;letter-spacing:1px;color:#f2a832;line-height:1;\">JM</td>");
            html.Append("</tr></table></td>");
        }

        private DbRuntimeRow ReadDbRuntimeRow(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Email_GetRuntimeConfig", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    return new DbRuntimeRow
                    {
                        SenderEmail = reader.IsDBNull(0) ? string.Empty : reader.GetString(0),
                        SenderName = reader.IsDBNull(1) ? string.Empty : reader.GetString(1),
                        EncryptedPassword = reader.IsDBNull(2) ? string.Empty : reader.GetString(2),
                        Host = reader.IsDBNull(3) ? DefaultSmtpHost : reader.GetString(3),
                        Port = reader.IsDBNull(4) ? DefaultSmtpPort : reader.GetInt32(4),
                        UseStartTls = reader.IsDBNull(5) || reader.GetBoolean(5)
                    };
                }
            }
        }

        private static EmailSettingsSummary ReadSummaryRow(SqlDataReader reader)
        {
            string senderEmail = reader.IsDBNull(0) ? string.Empty : reader.GetString(0).Trim();
            bool hasPassword = !reader.IsDBNull(5) && reader.GetBoolean(5);

            return new EmailSettingsSummary
            {
                SenderEmail = senderEmail,
                SenderName = reader.IsDBNull(1) ? DefaultSenderName : reader.GetString(1),
                SmtpHost = reader.IsDBNull(2) ? DefaultSmtpHost : reader.GetString(2),
                SmtpPort = reader.IsDBNull(3) ? DefaultSmtpPort : reader.GetInt32(3),
                UseStartTls = reader.IsDBNull(4) || reader.GetBoolean(4),
                HasPassword = hasPassword,
                IsConfigured = !string.IsNullOrWhiteSpace(senderEmail) && hasPassword,
                UpdatedAt = reader.IsDBNull(6) ? (DateTime?)null : reader.GetDateTime(6),
                UpdatedByName = reader.IsDBNull(7) ? null : reader.GetString(7)
            };
        }

        private static EmailSettingsSummary CreateEmptySummary()
        {
            var appDefaults = ReadAppConfigDefaults(DefaultSenderName);
            return new EmailSettingsSummary
            {
                SenderEmail = string.Empty,
                SenderName = appDefaults.SenderName,
                SmtpHost = appDefaults.Host,
                SmtpPort = appDefaults.Port,
                UseStartTls = appDefaults.UseStartTls,
                HasPassword = false,
                IsConfigured = false,
                UpdatedAt = null,
                UpdatedByName = null
            };
        }

        private static SmtpRuntimeConfig ReadAppConfigDefaults(string fallbackSenderName)
        {
            string host = (ConfigurationManager.AppSettings["SmtpHost"] ?? DefaultSmtpHost).Trim();
            string portRaw = (ConfigurationManager.AppSettings["SmtpPort"] ?? "587").Trim();
            string startTlsRaw = (ConfigurationManager.AppSettings["SmtpUseStartTls"] ?? "true").Trim();
            string senderName = (ConfigurationManager.AppSettings["SmtpSenderName"]
                ?? (string.IsNullOrWhiteSpace(fallbackSenderName) ? DefaultSenderName : fallbackSenderName)).Trim();
            string logoUrl = (ConfigurationManager.AppSettings["SmtpLogoUrl"] ?? DefaultLogoUrl).Trim();
            string timeoutRaw = (ConfigurationManager.AppSettings["SmtpTimeoutMs"] ?? "20000").Trim();
            string paymentTerms = (ConfigurationManager.AppSettings["PoPaymentTerms"] ?? DefaultPaymentTerms).Trim();

            if (!int.TryParse(portRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out int port)
                || port <= 0 || port > 65535)
            {
                port = DefaultSmtpPort;
            }

            if (!int.TryParse(timeoutRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out int timeoutMs)
                || timeoutMs < 3000)
            {
                timeoutMs = 20000;
            }

            return new SmtpRuntimeConfig
            {
                Host = string.IsNullOrWhiteSpace(host) ? DefaultSmtpHost : host,
                Port = port,
                UseStartTls = !string.Equals(startTlsRaw, "false", StringComparison.OrdinalIgnoreCase),
                SenderName = string.IsNullOrWhiteSpace(senderName) ? DefaultSenderName : senderName,
                LogoUrl = logoUrl,
                TimeoutMs = timeoutMs,
                PaymentTerms = string.IsNullOrWhiteSpace(paymentTerms) ? DefaultPaymentTerms : paymentTerms
            };
        }

        private sealed class DbRuntimeRow
        {
            public string SenderEmail { get; set; }
            public string SenderName { get; set; }
            public string EncryptedPassword { get; set; }
            public string Host { get; set; }
            public int Port { get; set; }
            public bool UseStartTls { get; set; }
        }
    }
}
