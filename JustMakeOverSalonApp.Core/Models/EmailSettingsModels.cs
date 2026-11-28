using System;
using System.Threading;
using System.Threading.Tasks;

namespace JustMakeOverSalonApp.Core.Models
{
    // Safe projection of Official Salon Email settings for the Settings UI
    // (never contains plaintext or encrypted password data).
    public sealed class EmailSettingsSummary
    {
        public string SenderEmail { get; set; }
        public string SenderName { get; set; }
        public string SmtpHost { get; set; }
        public int SmtpPort { get; set; }
        public bool UseStartTls { get; set; }
        public bool HasPassword { get; set; }
        public bool IsConfigured { get; set; }
        public DateTime? UpdatedAt { get; set; }
        public string UpdatedByName { get; set; }
    }

    // Complete runtime SMTP configuration used strictly inside C# services.
    public sealed class SmtpRuntimeConfig
    {
        public string Host { get; set; }
        public int Port { get; set; }
        public bool UseStartTls { get; set; }
        public string SenderEmail { get; set; }
        public string SenderName { get; set; }
        public string AppPassword { get; set; }
        public string LogoUrl { get; set; }
        public string PaymentTerms { get; set; }
        public int TimeoutMs { get; set; }
        public string Source { get; set; }
    }

    public delegate Task SmtpSendDelegate(
        SmtpRuntimeConfig config,
        string recipientEmail,
        string recipientName,
        string subject,
        string htmlBody,
        string textBody,
        CancellationToken cancellationToken);
}
