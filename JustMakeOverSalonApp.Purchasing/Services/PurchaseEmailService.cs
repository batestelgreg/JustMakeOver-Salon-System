using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Globalization;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Purchasing.Repositories;
using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;

namespace JustMakeOverSalonApp.Purchasing.Services
{
    // Asynchronous SMTP email service backed by MailKit.
    // Resolves the Admin-configured Official Salon Email from dbo.EMAIL_SETTINGS
    // (DPAPI-encrypted in SQL) on the C# side so Purchasing Staff never need
    // personal SMTP credentials and secrets are never exposed to WebView2 JS.
    public sealed class PurchaseEmailService
    {
        private readonly PurchasingRepository repository;
        private readonly EmailSettingsRepository emailSettingsRepository;

        public PurchaseEmailService(PurchasingRepository repository)
            : this(repository, new EmailSettingsRepository(new SqlConnectionFactory()))
        {
        }

        public PurchaseEmailService(
            PurchasingRepository repository,
            EmailSettingsRepository emailSettingsRepository)
        {
            this.repository = repository
                ?? throw new ArgumentNullException(nameof(repository));
            this.emailSettingsRepository = emailSettingsRepository
                ?? throw new ArgumentNullException(nameof(emailSettingsRepository));
        }

        public async Task<Dictionary<string, object>> SendPurchaseOrderAsync(
            CurrentUser actor,
            int poID,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireActor(actor);

            if (poID <= 0)
            {
                throw new BusinessException("A valid purchase order is required.");
            }

            // 1. Load live PO + supplier + signatory details from SQL.
            var order = repository.GetPurchaseOrderPrint(actor.UserID, poID);
            if (order == null)
            {
                throw new BusinessException("The purchase order could not be found.");
            }

            string poCode = "PO-" + poID.ToString("D4", CultureInfo.InvariantCulture);
            string salonName = ReadString(order, "SalonName", EmailSettingsRepository.DefaultSenderName);
            string supplierName = ReadString(order, "SupplierName", "Supplier");
            string recipientRaw = ReadString(order, "SupplierEmail", string.Empty).Trim();

            // 2. Validate supplier email before DB logging or MIME construction.
            if (!TryParseEmail(recipientRaw, out MailboxAddress recipientAddress))
            {
                throw new BusinessException(
                    string.IsNullOrWhiteSpace(recipientRaw)
                        ? "This supplier has no email address on file. Update the supplier record under Suppliers first."
                        : "The supplier email address (\"" + recipientRaw + "\") is not valid. Please update it under Suppliers.");
            }

            // 3. Resolve Official Salon Email (Admin-configured) BEFORE recording Pending log
            // so missing settings fail cleanly without creating spurious Failed log rows.
            SmtpRuntimeConfig config = emailSettingsRepository.ResolveRuntimeConfig(actor.UserID, salonName);

            string subject = string.Format(
                CultureInfo.InvariantCulture,
                "Purchase Order {0} — {1}",
                poCode,
                salonName);

            // 4. Record Pending attempt in dbo.EMAIL_LOGS (also re-validates in TSQL).
            long emailLogID;
            try
            {
                var pending = repository.BeginEmailLog(
                    actor.UserID,
                    poID,
                    "PURCHASE_ORDER",
                    null,
                    subject);

                emailLogID = Convert.ToInt64(pending["EmailLogID"], CultureInfo.InvariantCulture);
            }
            catch (SqlException sqlEx) when (sqlEx.Number >= 50000)
            {
                throw new BusinessException(sqlEx.Message);
            }

            // 5. Build business-standard HTML + plain-text PO message and send via MailKit.
            try
            {
                var message = BuildPurchaseOrderMimeMessage(
                    config,
                    recipientAddress,
                    supplierName,
                    subject,
                    poCode,
                    order);

                await SendViaSmtpAsync(config, message, cancellationToken).ConfigureAwait(false);

                var completed = repository.CompleteEmailLog(
                    actor.UserID,
                    emailLogID,
                    "Sent",
                    null,
                    markDispatched: true);

                completed["Message"] = string.Format(
                    CultureInfo.InvariantCulture,
                    "{0} was emailed to {1} from {2}.",
                    poCode,
                    recipientAddress.Address,
                    config.SenderEmail);

                return completed;
            }
            catch (Exception ex)
            {
                string friendlyError = FormatSmtpError(ex);
                TryRecordFailure(actor.UserID, emailLogID, friendlyError);
                throw new BusinessException(friendlyError);
            }
        }

        public async Task<Dictionary<string, object>> SendFollowupReminderAsync(
            CurrentUser actor,
            int poID,
            int followupID,
            string reminderMessage,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireActor(actor);

            if (poID <= 0 || followupID <= 0)
            {
                throw new BusinessException("A valid follow-up reminder is required.");
            }

            var order = repository.GetPurchaseOrderPrint(actor.UserID, poID);
            if (order == null)
            {
                throw new BusinessException("The related purchase order could not be found.");
            }

            string poCode = "PO-" + poID.ToString("D4", CultureInfo.InvariantCulture);
            string salonName = ReadString(order, "SalonName", EmailSettingsRepository.DefaultSenderName);
            string supplierName = ReadString(order, "SupplierName", "Supplier");
            string recipientRaw = ReadString(order, "SupplierEmail", string.Empty).Trim();

            if (!TryParseEmail(recipientRaw, out MailboxAddress recipientAddress))
            {
                throw new BusinessException(
                    string.IsNullOrWhiteSpace(recipientRaw)
                        ? "This supplier has no email address on file. Update the supplier record under Suppliers first."
                        : "The supplier email address (\"" + recipientRaw + "\") is not valid. Please update it under Suppliers.");
            }

            SmtpRuntimeConfig config = emailSettingsRepository.ResolveRuntimeConfig(actor.UserID, salonName);

            string subject = string.Format(
                CultureInfo.InvariantCulture,
                "Delivery Follow-Up: {0} — {1}",
                poCode,
                salonName);

            long emailLogID;
            try
            {
                var pending = repository.BeginEmailLog(
                    actor.UserID,
                    poID,
                    "FOLLOW_UP",
                    followupID,
                    subject);

                emailLogID = Convert.ToInt64(pending["EmailLogID"], CultureInfo.InvariantCulture);
            }
            catch (SqlException sqlEx) when (sqlEx.Number >= 50000)
            {
                throw new BusinessException(sqlEx.Message);
            }

            try
            {
                var message = BuildFollowupMimeMessage(
                    config,
                    recipientAddress,
                    supplierName,
                    subject,
                    poCode,
                    order,
                    reminderMessage);

                await SendViaSmtpAsync(config, message, cancellationToken).ConfigureAwait(false);

                var completed = repository.CompleteEmailLog(
                    actor.UserID,
                    emailLogID,
                    "Sent",
                    null,
                    markDispatched: false);

                completed["Message"] = string.Format(
                    CultureInfo.InvariantCulture,
                    "Follow-up reminder for {0} was emailed to {1} from {2}.",
                    poCode,
                    recipientAddress.Address,
                    config.SenderEmail);

                return completed;
            }
            catch (Exception ex)
            {
                string friendlyError = FormatSmtpError(ex);
                TryRecordFailure(actor.UserID, emailLogID, friendlyError);
                throw new BusinessException(friendlyError);
            }
        }

        public async Task<Dictionary<string, object>> SendReplacementRequestAsync(
            CurrentUser actor,
            int poID,
            int drID,
            int replacementQty,
            string deliveryReference,
            string customSubject,
            string customBody,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireActor(actor);

            if (poID <= 0 || drID <= 0)
            {
                throw new BusinessException("A valid purchase order delivery record is required.");
            }

            if (string.IsNullOrWhiteSpace(customBody))
            {
                throw new BusinessException("Please enter an email message before sending.");
            }

            var order = repository.GetPurchaseOrderPrint(actor.UserID, poID);
            if (order == null)
            {
                throw new BusinessException("The related purchase order could not be found.");
            }

            string poCode = "PO-" + poID.ToString("D4", CultureInfo.InvariantCulture);
            string salonName = ReadString(order, "SalonName", EmailSettingsRepository.DefaultSenderName);
            string supplierName = ReadString(order, "SupplierName", "Supplier");
            string recipientRaw = ReadString(order, "SupplierEmail", string.Empty).Trim();

            if (!TryParseEmail(recipientRaw, out MailboxAddress recipientAddress))
            {
                throw new BusinessException(
                    string.IsNullOrWhiteSpace(recipientRaw)
                        ? "This supplier has no email address on file. Update the supplier record under Suppliers first."
                        : "The supplier email address (\"" + recipientRaw + "\") is not valid. Please update it under Suppliers.");
            }

            SmtpRuntimeConfig config = emailSettingsRepository.ResolveRuntimeConfig(actor.UserID, salonName);

            string subject = string.IsNullOrWhiteSpace(customSubject)
                ? string.Format(
                    CultureInfo.InvariantCulture,
                    "Replacement Request: {0} — {1}",
                    poCode,
                    salonName)
                : customSubject.Trim();

            if (subject.Length > 250)
            {
                subject = subject.Substring(0, 250);
            }

            long emailLogID;
            try
            {
                var pending = repository.BeginEmailLog(
                    actor.UserID,
                    poID,
                    "REPLACEMENT_REQUEST",
                    null,
                    subject);

                emailLogID = Convert.ToInt64(pending["EmailLogID"], CultureInfo.InvariantCulture);
            }
            catch (SqlException sqlEx) when (sqlEx.Number >= 50000)
            {
                throw new BusinessException(sqlEx.Message);
            }

            try
            {
                var message = BuildReplacementMimeMessage(
                    config,
                    recipientAddress,
                    supplierName,
                    subject,
                    poCode,
                    order,
                    drID,
                    replacementQty,
                    deliveryReference,
                    customBody.Trim());

                await SendViaSmtpAsync(config, message, cancellationToken).ConfigureAwait(false);

                var completed = repository.CompleteEmailLog(
                    actor.UserID,
                    emailLogID,
                    "Sent",
                    null,
                    markDispatched: false);

                completed["Message"] = string.Format(
                    CultureInfo.InvariantCulture,
                    "Replacement request for {0} was emailed to {1} from {2}.",
                    poCode,
                    recipientAddress.Address,
                    config.SenderEmail);

                return completed;
            }
            catch (Exception ex)
            {
                string friendlyError = FormatSmtpError(ex);
                TryRecordFailure(actor.UserID, emailLogID, friendlyError);
                throw new BusinessException(friendlyError);
            }
        }

        // Shared MailKit transport entry point registered with Core so Settings Test Email
        // uses the exact same SMTP connection and friendly error formatting without duplication.
        public static async Task SendEmailDirectAsync(
            SmtpRuntimeConfig config,
            string recipientEmail,
            string recipientName,
            string subject,
            string htmlBody,
            string textBody,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (config == null)
            {
                throw new ArgumentNullException(nameof(config));
            }

            if (!TryParseEmail(config.SenderEmail, out MailboxAddress senderAddress))
            {
                throw new BusinessException(
                    "The Official Salon Email address is invalid. Please update it under Settings -> Official Salon Email.");
            }

            if (!TryParseEmail(recipientEmail, out MailboxAddress recipientAddress))
            {
                throw new BusinessException("Please enter a valid recipient email address.");
            }

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(config.SenderName, senderAddress.Address));
            message.To.Add(new MailboxAddress(
                string.IsNullOrWhiteSpace(recipientName) ? recipientAddress.Address : recipientName.Trim(),
                recipientAddress.Address));
            message.Subject = subject ?? string.Empty;

            var builder = new BodyBuilder
            {
                HtmlBody = htmlBody,
                TextBody = textBody
            };
            message.Body = builder.ToMessageBody();

            try
            {
                await SendViaSmtpAsync(config, message, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (!(ex is OperationCanceledException))
            {
                throw new BusinessException(FormatSmtpError(ex));
            }
        }

        private static async Task SendViaSmtpAsync(
            SmtpRuntimeConfig config,
            MimeMessage message,
            CancellationToken cancellationToken)
        {
            using (var client = new SmtpClient())
            {
                client.Timeout = config.TimeoutMs;

                SecureSocketOptions socketOptions = config.Port == 465
                    ? SecureSocketOptions.SslOnConnect
                    : (config.UseStartTls
                        ? SecureSocketOptions.StartTls
                        : SecureSocketOptions.Auto);

                await client.ConnectAsync(
                    config.Host,
                    config.Port,
                    socketOptions,
                    cancellationToken).ConfigureAwait(false);

                await client.AuthenticateAsync(
                    config.SenderEmail,
                    config.AppPassword,
                    cancellationToken).ConfigureAwait(false);

                await client.SendAsync(message, cancellationToken).ConfigureAwait(false);
                await client.DisconnectAsync(true, cancellationToken).ConfigureAwait(false);
            }
        }

        private static MimeMessage BuildPurchaseOrderMimeMessage(
            SmtpRuntimeConfig config,
            MailboxAddress recipientAddress,
            string supplierName,
            string subject,
            string poCode,
            Dictionary<string, object> order)
        {
            string salonName = ReadString(order, "SalonName", config.SenderName);
            string salonTagline = ReadString(order, "SalonTagline", "Beauty Salon & Spa");
            string supplierCode = ReadString(order, "SupplierCode", string.Empty);
            string supplierContact = ReadString(order, "SupplierContact", string.Empty);
            string supplierPhone = ReadString(order, "SupplierPhone", string.Empty);
            string supplierAddress = ReadString(order, "SupplierAddress", string.Empty);

            string itemCode = ReadString(order, "ItemCode", string.Empty);
            string itemName = ReadString(order, "ItemName", string.Empty);
            string uom = ReadString(order, "UnitOfMeasure", "unit");
            int qtyOrdered = ReadInt(order, "QuantityOrdered");
            decimal unitPrice = ReadDecimal(order, "UnitPrice");
            decimal totalAmount = ReadDecimal(order, "TotalAmount");

            string orderDate = FormatDate(order, "DateIssued");
            string expectedDate = FormatDate(order, "ExpectedDate");
            string prCode = "PR-" + ReadInt(order, "PRID").ToString("D4", CultureInfo.InvariantCulture);
            string requestedBy = ReadString(order, "RequestedByName", "Purchasing Staff");
            string approvedBy = ReadString(order, "ApprovedByName", "Authorized Management");
            string paymentTerms = config.PaymentTerms;

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(config.SenderName, config.SenderEmail));
            message.To.Add(new MailboxAddress(supplierName, recipientAddress.Address));
            message.Subject = subject;

            var builder = new BodyBuilder();

            var html = new StringBuilder(4096);
            html.Append("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head>");
            html.Append("<body style=\"margin:0;padding:24px;background-color:#f4f6f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#182538;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:680px;margin:0 auto;background-color:#ffffff;border:1px solid #dce3ec;border-radius:10px;overflow:hidden;\">");

            // Business header banner with gold-outlined hosted logo (zero image attachments)
            html.Append("<tr><td style=\"background-color:#132436;padding:22px 28px;color:#ffffff;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
            html.Append("<td style=\"vertical-align:middle;\">");
            html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
            EmailSettingsRepository.AppendBrandLogoCell(html, config.LogoUrl, salonName, 54);
            html.Append("<td style=\"vertical-align:middle;\">");
            html.Append("<div style=\"font-size:21px;font-weight:700;letter-spacing:0.3px;\">").Append(H(salonName)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(salonTagline))
            {
                html.Append("<div style=\"font-size:12px;color:#c7d4e2;margin-top:3px;\">").Append(H(salonTagline)).Append("</div>");
            }
            html.Append("</td></tr></table></td>");
            html.Append("<td style=\"text-align:right;vertical-align:middle;\">");
            html.Append("<div style=\"font-size:11px;text-transform:uppercase;letter-spacing:1.2px;color:#f2a832;font-weight:700;\">Purchase Order</div>");
            html.Append("<div style=\"font-size:20px;font-weight:700;margin-top:2px;\">").Append(H(poCode)).Append("</div>");
            html.Append("</td></tr></table></td></tr>");

            // Intro
            html.Append("<tr><td style=\"padding:24px 28px 10px;\">");
            html.Append("<p style=\"margin:0 0 12px;font-size:14px;line-height:1.6;\">Dear <strong>").Append(H(supplierName)).Append("</strong>,</p>");
            html.Append("<p style=\"margin:0;font-size:14px;line-height:1.6;color:#394b61;\">Please find below our official Purchase Order. Kindly confirm receipt and notify us if there are any changes to the expected delivery schedule.</p>");
            html.Append("</td></tr>");

            // Metadata & Supplier grid
            html.Append("<tr><td style=\"padding:12px 28px;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border:1px solid #e2e8f0;border-radius:8px;background-color:#f8fafc;\">");
            html.Append("<tr>");
            html.Append("<td width=\"50%\" style=\"padding:14px 16px;vertical-align:top;border-right:1px solid #e2e8f0;\">");
            html.Append("<div style=\"font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:0.6px;color:#526477;margin-bottom:6px;\">Supplier Details</div>");
            html.Append("<div style=\"font-size:14px;font-weight:700;color:#10283f;\">").Append(H(supplierName)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(supplierCode))
                html.Append("<div style=\"font-size:12px;color:#526477;margin-top:2px;\">Code: ").Append(H(supplierCode)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(supplierContact))
                html.Append("<div style=\"font-size:12px;color:#394b61;margin-top:4px;\">Attn: ").Append(H(supplierContact)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(supplierPhone))
                html.Append("<div style=\"font-size:12px;color:#394b61;margin-top:2px;\">Phone: ").Append(H(supplierPhone)).Append("</div>");
            html.Append("<div style=\"font-size:12px;color:#394b61;margin-top:2px;\">Email: ").Append(H(recipientAddress.Address)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(supplierAddress))
                html.Append("<div style=\"font-size:12px;color:#526477;margin-top:4px;\">").Append(H(supplierAddress)).Append("</div>");
            html.Append("</td>");

            html.Append("<td width=\"50%\" style=\"padding:14px 16px;vertical-align:top;\">");
            html.Append("<div style=\"font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:0.6px;color:#526477;margin-bottom:6px;\">Order Information</div>");
            AppendMetaRow(html, "PO Number", poCode);
            AppendMetaRow(html, "Reference PR", prCode);
            AppendMetaRow(html, "Order Date", orderDate);
            AppendMetaRow(html, "Expected Delivery", expectedDate);
            AppendMetaRow(html, "Payment Terms", paymentTerms);
            html.Append("</td></tr></table></td></tr>");

            // Itemized table
            html.Append("<tr><td style=\"padding:12px 28px;\">");
            html.Append("<div style=\"font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:0.6px;color:#10283f;margin-bottom:8px;\">Order Details</div>");
            html.Append("<table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;font-size:13px;\">");
            html.Append("<thead><tr style=\"background-color:#eef3f8;color:#10283f;\">");
            html.Append("<th style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:left;\">Item</th>");
            html.Append("<th style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:left;\">Unit</th>");
            html.Append("<th style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;\">Qty</th>");
            html.Append("<th style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;\">Unit Price</th>");
            html.Append("<th style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;\">Line Total</th>");
            html.Append("</tr></thead><tbody><tr>");
            html.Append("<td style=\"padding:10px 8px;border:1px solid #d5dfe9;\"><strong>").Append(H(itemName)).Append("</strong>");
            if (!string.IsNullOrWhiteSpace(itemCode))
            {
                html.Append("<div style=\"font-size:11px;color:#64748b;\">Code: ").Append(H(itemCode)).Append("</div>");
            }
            html.Append("</td>");
            html.Append("<td style=\"padding:10px 8px;border:1px solid #d5dfe9;\">").Append(H(uom)).Append("</td>");
            html.Append("<td style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;\">").Append(qtyOrdered.ToString("N0", CultureInfo.InvariantCulture)).Append("</td>");
            html.Append("<td style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;\">").Append(H(FormatMoney(unitPrice))).Append("</td>");
            html.Append("<td style=\"padding:10px 8px;border:1px solid #d5dfe9;text-align:right;font-weight:600;\">").Append(H(FormatMoney(totalAmount))).Append("</td>");
            html.Append("</tr></tbody><tfoot><tr style=\"background-color:#f8fafc;\">");
            html.Append("<td colspan=\"4\" style=\"padding:11px 8px;border:1px solid #d5dfe9;text-align:right;font-weight:700;font-size:14px;\">Grand Total</td>");
            html.Append("<td style=\"padding:11px 8px;border:1px solid #d5dfe9;text-align:right;font-weight:700;font-size:14px;color:#10283f;\">").Append(H(FormatMoney(totalAmount))).Append("</td>");
            html.Append("</tr></tfoot></table></td></tr>");

            // Terms & Signatories
            html.Append("<tr><td style=\"padding:10px 28px 20px;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:8px;border-top:1px solid #e2e8f0;padding-top:14px;\"><tr>");
            html.Append("<td width=\"50%\" style=\"padding-top:12px;vertical-align:top;\">");
            html.Append("<div style=\"font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.5px;\">Requested By</div>");
            html.Append("<div style=\"font-size:13px;font-weight:700;color:#10283f;margin-top:4px;\">").Append(H(requestedBy)).Append("</div>");
            html.Append("</td>");
            html.Append("<td width=\"50%\" style=\"padding-top:12px;vertical-align:top;text-align:right;\">");
            html.Append("<div style=\"font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.5px;\">Authorized Signatory</div>");
            html.Append("<div style=\"font-size:13px;font-weight:700;color:#10283f;margin-top:4px;\">").Append(H(approvedBy)).Append("</div>");
            html.Append("</td></tr></table>");
            html.Append("<p style=\"margin:16px 0 0;font-size:12px;color:#64748b;line-height:1.5;\">Please reference <strong>").Append(H(poCode)).Append("</strong> on your delivery receipt and invoice. Delivery is subject to inspection and acceptance upon arrival.</p>");
            html.Append("</td></tr>");

            // Footer
            html.Append("<tr><td style=\"background-color:#f8fafc;border-top:1px solid #e2e8f0;padding:12px 28px;font-size:11px;color:#64748b;text-align:center;\">");
            html.Append(H(salonName)).Append(" &middot; Official Purchase Order Communication");
            html.Append("</td></tr></table></body></html>");

            var plainText = new StringBuilder();
            plainText.AppendLine(salonName);
            plainText.AppendLine("PURCHASE ORDER " + poCode);
            plainText.AppendLine(new string('-', 42));
            plainText.AppendLine("Supplier: " + supplierName);
            plainText.AppendLine("Order Date: " + orderDate);
            plainText.AppendLine("Expected Delivery: " + expectedDate);
            plainText.AppendLine("Payment Terms: " + paymentTerms);
            plainText.AppendLine();
            plainText.AppendLine("Item: " + (string.IsNullOrWhiteSpace(itemCode) ? itemName : itemCode + " - " + itemName));
            plainText.AppendLine("Unit: " + uom);
            plainText.AppendLine("Quantity: " + qtyOrdered);
            plainText.AppendLine("Unit Price: " + FormatMoney(unitPrice));
            plainText.AppendLine("Grand Total: " + FormatMoney(totalAmount));
            plainText.AppendLine();
            plainText.AppendLine("Requested By: " + requestedBy);
            plainText.AppendLine("Authorized Signatory: " + approvedBy);

            builder.HtmlBody = html.ToString();
            builder.TextBody = plainText.ToString();
            message.Body = builder.ToMessageBody();

            return message;
        }

        private static MimeMessage BuildFollowupMimeMessage(
            SmtpRuntimeConfig config,
            MailboxAddress recipientAddress,
            string supplierName,
            string subject,
            string poCode,
            Dictionary<string, object> order,
            string reminderMessage)
        {
            string salonName = ReadString(order, "SalonName", config.SenderName);
            string salonTagline = ReadString(order, "SalonTagline", "Beauty Salon & Spa");
            string itemName = ReadString(order, "ItemName", string.Empty);
            string expectedDate = FormatDate(order, "ExpectedDate");
            int outstanding = ReadInt(order, "OutstandingQuantity");
            string bodyNote = string.IsNullOrWhiteSpace(reminderMessage)
                ? string.Format(
                    CultureInfo.InvariantCulture,
                    "Please provide a delivery status update for {0} ({1}, outstanding quantity: {2}, expected date: {3}).",
                    poCode,
                    itemName,
                    outstanding,
                    expectedDate)
                : reminderMessage.Trim();

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(config.SenderName, config.SenderEmail));
            message.To.Add(new MailboxAddress(supplierName, recipientAddress.Address));
            message.Subject = subject;

            var builder = new BodyBuilder();

            var html = new StringBuilder(2048);
            html.Append("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head>");
            html.Append("<body style=\"margin:0;padding:24px;background-color:#f4f6f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#182538;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:620px;margin:0 auto;background-color:#ffffff;border:1px solid #dce3ec;border-radius:10px;overflow:hidden;\">");
            html.Append("<tr><td style=\"background-color:#132436;padding:20px 26px;color:#ffffff;\">");
            html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
            EmailSettingsRepository.AppendBrandLogoCell(html, config.LogoUrl, salonName, 48);
            html.Append("<td style=\"vertical-align:middle;\">");
            html.Append("<div style=\"font-size:19px;font-weight:700;\">").Append(H(salonName)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(salonTagline))
                html.Append("<div style=\"font-size:12px;color:#c7d4e2;margin-top:2px;\">").Append(H(salonTagline)).Append("</div>");
            html.Append("</td></tr></table></td></tr>");
            html.Append("<tr><td style=\"padding:24px 26px;\">");
            html.Append("<p style=\"margin:0 0 12px;font-size:14px;\">Dear <strong>").Append(H(supplierName)).Append("</strong>,</p>");
            html.Append("<p style=\"margin:0 0 16px;font-size:14px;line-height:1.6;color:#394b61;\">").Append(H(bodyNote)).Append("</p>");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border:1px solid #e2e8f0;border-radius:8px;background-color:#f8fafc;padding:12px 16px;\"><tr><td style=\"padding:12px 16px;\">");
            AppendMetaRow(html, "Purchase Order", poCode);
            AppendMetaRow(html, "Item", itemName);
            AppendMetaRow(html, "Outstanding Quantity", outstanding.ToString("N0", CultureInfo.InvariantCulture));
            AppendMetaRow(html, "Expected Delivery", expectedDate);
            html.Append("</td></tr></table>");
            html.Append("<p style=\"margin:16px 0 0;font-size:13px;color:#526477;\">Kindly reply with the updated delivery schedule at your earliest convenience. Thank you.</p>");
            html.Append("</td></tr>");
            html.Append("<tr><td style=\"background-color:#f8fafc;border-top:1px solid #e2e8f0;padding:12px 26px;font-size:11px;color:#64748b;text-align:center;\">");
            html.Append(H(salonName)).Append(" &middot; Delivery Follow-Up");
            html.Append("</td></tr></table></body></html>");

            builder.HtmlBody = html.ToString();
            builder.TextBody = string.Format(
                CultureInfo.InvariantCulture,
                "Dear {0},\n\n{1}\n\nPurchase Order: {2}\nItem: {3}\nOutstanding Quantity: {4}\nExpected Delivery: {5}\n\nThank you,\n{6}",
                supplierName,
                bodyNote,
                poCode,
                itemName,
                outstanding,
                expectedDate,
                salonName);
            message.Body = builder.ToMessageBody();

            return message;
        }

        private static MimeMessage BuildReplacementMimeMessage(
            SmtpRuntimeConfig config,
            MailboxAddress recipientAddress,
            string supplierName,
            string subject,
            string poCode,
            Dictionary<string, object> order,
            int drID,
            int replacementQty,
            string deliveryReference,
            string draftBody)
        {
            string salonName = ReadString(order, "SalonName", config.SenderName);
            string salonTagline = ReadString(order, "SalonTagline", "Beauty Salon & Spa");
            string itemName = ReadString(order, "ItemName", string.Empty);
            string refCode = string.IsNullOrWhiteSpace(deliveryReference)
                ? "DR-" + drID.ToString("D4", CultureInfo.InvariantCulture)
                : deliveryReference.Trim();

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(config.SenderName, config.SenderEmail));
            message.To.Add(new MailboxAddress(supplierName, recipientAddress.Address));
            message.Subject = subject;

            var builder = new BodyBuilder();

            string htmlMessage = H(draftBody)
                .Replace("\r\n", "\n")
                .Replace("\r", "\n")
                .Replace("\n", "<br>");

            var html = new StringBuilder(2048);
            html.Append("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head>");
            html.Append("<body style=\"margin:0;padding:24px;background-color:#f4f6f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#182538;\">");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:620px;margin:0 auto;background-color:#ffffff;border:1px solid #dce3ec;border-radius:10px;overflow:hidden;\">");
            html.Append("<tr><td style=\"background-color:#0f1d2e;padding:20px 26px;color:#ffffff;\">");
            html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
            EmailSettingsRepository.AppendBrandLogoCell(html, config.LogoUrl, salonName, 48);
            html.Append("<td style=\"vertical-align:middle;\">");
            html.Append("<div style=\"font-size:19px;font-weight:700;\">").Append(H(salonName)).Append("</div>");
            if (!string.IsNullOrWhiteSpace(salonTagline))
                html.Append("<div style=\"font-size:12px;color:#c7d4e2;margin-top:2px;\">").Append(H(salonTagline)).Append("</div>");
            html.Append("</td></tr></table></td></tr>");
            html.Append("<tr><td style=\"padding:24px 26px;\">");
            html.Append("<div style=\"font-size:14px;line-height:1.65;color:#182638;margin-bottom:18px;\">").Append(htmlMessage).Append("</div>");
            html.Append("<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border:1px solid #dce3ec;border-radius:8px;background-color:#f8fafc;\"><tr><td style=\"padding:12px 16px;\">");
            AppendMetaRow(html, "Purchase Order", poCode);
            AppendMetaRow(html, "Delivery Reference", refCode);
            AppendMetaRow(html, "Item", itemName);
            if (replacementQty > 0)
            {
                AppendMetaRow(html, "Replacement Quantity Needed", replacementQty.ToString("N0", CultureInfo.InvariantCulture));
            }
            html.Append("</td></tr></table>");
            html.Append("</td></tr>");
            html.Append("<tr><td style=\"background-color:#f8fafc;border-top:1px solid #dce3ec;padding:12px 26px;font-size:11px;color:#64748b;text-align:center;\">");
            html.Append(H(salonName)).Append(" &middot; Replacement Request");
            html.Append("</td></tr></table></body></html>");

            builder.HtmlBody = html.ToString();
            builder.TextBody = draftBody;
            message.Body = builder.ToMessageBody();

            return message;
        }

        private static void AppendMetaRow(StringBuilder html, string label, string value)
        {
            html.Append("<div style=\"font-size:12px;margin-top:4px;color:#394b61;\"><span style=\"color:#64748b;\">")
                .Append(H(label))
                .Append(":</span> <strong>")
                .Append(H(value))
                .Append("</strong></div>");
        }

        private static bool TryParseEmail(string raw, out MailboxAddress parsed)
        {
            parsed = null;
            if (!EmailSettingsRepository.IsValidEmailFormat(raw))
            {
                return false;
            }

            return MailboxAddress.TryParse(raw.Trim(), out parsed);
        }

        private void TryRecordFailure(int actorUserID, long emailLogID, string errorMessage)
        {
            try
            {
                repository.CompleteEmailLog(
                    actorUserID,
                    emailLogID,
                    "Failed",
                    errorMessage,
                    markDispatched: false);
            }
            catch
            {
                // Preserve the original SMTP error if failure logging itself fails.
            }
        }

        private static string FormatSmtpError(Exception ex)
        {
            if (ex is BusinessException)
            {
                return ex.Message;
            }

            if (ex is AuthenticationException)
            {
                return "SMTP authentication failed. Ask an Administrator to verify the Official Salon Email and 16-character Google App Password under Settings -> Official Salon Email.";
            }

            if (ex is SmtpCommandException cmdEx)
            {
                return "SMTP server rejected the email (" + cmdEx.StatusCode + "): " + cmdEx.Message;
            }

            if (ex is SmtpProtocolException)
            {
                return "SMTP protocol error while sending email: " + ex.Message;
            }

            return "Unable to send email via SMTP: " + ex.Message;
        }

        private static string ReadString(Dictionary<string, object> row, string key, string fallback)
        {
            if (row == null || !row.TryGetValue(key, out object value) || value == null)
            {
                return fallback;
            }

            string text = Convert.ToString(value, CultureInfo.InvariantCulture);
            return string.IsNullOrWhiteSpace(text) ? fallback : text.Trim();
        }

        private static int ReadInt(Dictionary<string, object> row, string key)
        {
            if (row == null || !row.TryGetValue(key, out object value) || value == null)
            {
                return 0;
            }

            return Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }

        private static decimal ReadDecimal(Dictionary<string, object> row, string key)
        {
            if (row == null || !row.TryGetValue(key, out object value) || value == null)
            {
                return 0m;
            }

            return Convert.ToDecimal(value, CultureInfo.InvariantCulture);
        }

        private static string FormatDate(Dictionary<string, object> row, string key)
        {
            if (row == null || !row.TryGetValue(key, out object value) || value == null)
            {
                return "—";
            }

            if (value is DateTime dt)
            {
                return dt.ToString("MMM dd, yyyy", CultureInfo.InvariantCulture);
            }

            string text = Convert.ToString(value, CultureInfo.InvariantCulture);
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out DateTime parsed))
            {
                return parsed.ToString("MMM dd, yyyy", CultureInfo.InvariantCulture);
            }

            return string.IsNullOrWhiteSpace(text) ? "—" : text;
        }

        private static string FormatMoney(decimal amount)
        {
            return "PHP " + amount.ToString("#,##0.00", CultureInfo.InvariantCulture);
        }

        private static string H(string text)
        {
            return WebUtility.HtmlEncode(text ?? string.Empty);
        }

        private static void RequireActor(CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException("Please sign in before sending supplier emails.");
            }
        }
    }
}
