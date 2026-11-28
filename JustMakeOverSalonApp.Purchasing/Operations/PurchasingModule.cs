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
        private PurchaseEmailService emailService;

        public void RegisterOperations(
            OperationRegistry registry,
            IOperationContext context)
        {
            this.context = context;

            var repo = new PurchasingRepository(new SqlConnectionFactory());
            service = new PurchasingService(repo);
            emailService = new PurchaseEmailService(repo);

            registry.Register(
                "PurchasingWorkspaceLoad", HandleLoadAsync);

            registry.Register(
                "PurchasingWorkspaceAction", HandleActionAsync);

            // Real SMTP email dispatch via MailKit (credentials stay strictly in C#).
            registry.Register(
                "PurchasingSendPOEmail",
                HandleSendPOEmailAsync);

            registry.Register(
                "PurchasingSendFollowupEmail",
                HandleSendFollowupEmailAsync);

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
            var actor = context.RequireUser();

            if (string.Equals(action, "ApprovePO", System.StringComparison.Ordinal))
            {
                int poID = ParseID(context.GetValueAsString(payload, "poID"));
                string signature = context.GetValueAsString(payload, "signature");
                bool confirmed = ParseBool(context.GetValueAsString(payload, "confirmed"));

                var approvalResult = await service.ApprovePOWithSignatureAsync(
                    actor,
                    poID,
                    signature,
                    confirmed);

                context.SendResponse(requestID, true, approvalResult, null);
                return;
            }

            // By-process signing for CreatePR (signs RepF Approved), CreatePO
            // (signs PO Requested), and RecordDR (signs Delivery Check Checked).
            bool requiresInlineSign =
                string.Equals(action, "CreatePR", System.StringComparison.Ordinal)
                || string.Equals(action, "CreatePO", System.StringComparison.Ordinal)
                || string.Equals(action, "RecordDR", System.StringComparison.Ordinal);

            string inlineSig = null;
            if (requiresInlineSign)
            {
                inlineSig = context.GetValueAsString(payload, "signature");
                bool inlineConfirmed = ParseBool(context.GetValueAsString(payload, "confirmed"));
                if (!inlineConfirmed)
                {
                    throw new JustMakeOverSalonApp.Core.Validation.BusinessException(
                        "Please confirm your signature before proceeding.");
                }
                JustMakeOverSalonApp.Core.Services.DocumentSignatureService.ValidateSignatureImage(
                    inlineSig,
                    "A digital signature is required to complete this step.");
            }

            // Strip signature payload before sending JSON to Purchasing workspace proc.
            var actionPayload = new Dictionary<string, object>(payload);
            actionPayload.Remove("signature");
            actionPayload.Remove("confirmed");

            // Serialize input values, never interpolate them into SQL.
            var serializer = new JavaScriptSerializer();
            string json = serializer.Serialize(actionPayload);

            var result = await service.ExecuteAsync(
                actor, action, json);

            if (requiresInlineSign && !string.IsNullOrWhiteSpace(inlineSig))
            {
                var sigRepo = new DocumentSignatureRepository(new SqlConnectionFactory());
                if (string.Equals(action, "CreatePR", System.StringComparison.Ordinal))
                {
                    int repFID = ParseID(context.GetValueAsString(payload, "repFID"));
                    if (repFID > 0)
                    {
                        try
                        {
                            sigRepo.Sign(actor.UserID, "REPLENISHMENT_REQUEST", repFID, "Approved", inlineSig, true);
                        }
                        catch
                        {
                            // Ignore if this RepF already has an active Approved signature (e.g. re-opened PR).
                        }
                    }
                }
                else if (string.Equals(action, "CreatePO", System.StringComparison.Ordinal))
                {
                    int poID = result != null && result.ContainsKey("ID") && result["ID"] != null
                        ? ParseID(result["ID"].ToString())
                        : 0;
                    if (poID > 0)
                    {
                        sigRepo.Sign(actor.UserID, "PURCHASE_ORDER", poID, "Requested", inlineSig, true);
                    }
                }
                else if (string.Equals(action, "RecordDR", System.StringComparison.Ordinal))
                {
                    int drID = result != null && result.ContainsKey("ID") && result["ID"] != null
                        ? ParseID(result["ID"].ToString())
                        : 0;
                    if (drID > 0)
                    {
                        sigRepo.Sign(actor.UserID, "DELIVERY_CHECK", drID, "Checked", inlineSig, true);
                    }
                }
            }

            context.SendResponse(requestID, true, result, null);
        }

        // Sends the Purchase Order HTML email asynchronously via MailKit SMTP
        // and updates dbo.EMAIL_LOGS + PO dispatch status.
        private async Task HandleSendPOEmailAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var result = await emailService.SendPurchaseOrderAsync(
                context.RequireUser(),
                ParseID(context.GetValueAsString(payload, "poID")));

            context.SendResponse(requestID, true, result, null);
        }

        // Sends a delivery follow-up reminder email asynchronously via MailKit SMTP.
        private async Task HandleSendFollowupEmailAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var result = await emailService.SendFollowupReminderAsync(
                context.RequireUser(),
                ParseID(context.GetValueAsString(payload, "poID")),
                ParseID(context.GetValueAsString(payload, "followupID")),
                context.GetValueAsString(payload, "message"));

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

        private static bool ParseBool(string text)
        {
            return string.Equals(text, "true", System.StringComparison.OrdinalIgnoreCase)
                || text == "1";
        }
    }
}