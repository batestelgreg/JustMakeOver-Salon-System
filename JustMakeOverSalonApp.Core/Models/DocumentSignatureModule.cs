using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Services;

namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga module kay nag-register sa shared digital signature
    // operations (Get, Sign, Revoke, Verify) para sa tanang internal documents.
    public sealed class DocumentSignatureModule : IModuleOperations
    {
        private IOperationContext context;
        private DocumentSignatureService service;

        public void RegisterOperations(
            OperationRegistry registry,
            IOperationContext context)
        {
            this.context = context;
            service = new DocumentSignatureService(
                new DocumentSignatureRepository(new SqlConnectionFactory()));

            registry.Register("DocumentSignatureGet", HandleGetAsync);
            registry.Register("DocumentSignatureSign", HandleSignAsync);
            registry.Register("DocumentSignatureRevoke", HandleRevokeAsync);
            registry.Register("DocumentSignatureVerify", HandleVerifyAsync);
        }

        private async Task HandleGetAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var result = await service.GetAsync(
                context.RequireUser(),
                context.GetValueAsString(payload, "documentType"),
                context.GetValueAsInt(payload, "documentID"));

            context.SendResponse(requestID, true, result, null);
        }

        private async Task HandleSignAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            bool confirmed = ParseBool(
                context.GetValueAsString(payload, "confirmed"));

            var result = await service.SignAsync(
                context.RequireUser(),
                context.GetValueAsString(payload, "documentType"),
                context.GetValueAsInt(payload, "documentID"),
                context.GetValueAsString(payload, "stage"),
                context.GetValueAsString(payload, "signatureImage"),
                confirmed);

            context.SendResponse(requestID, true, result, null);
        }

        private async Task HandleRevokeAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            long.TryParse(
                context.GetValueAsString(payload, "signatureID"),
                out long signatureID);

            var result = await service.RevokeAsync(
                context.RequireUser(),
                signatureID,
                context.GetValueAsString(payload, "reason"));

            context.SendResponse(requestID, true, result, null);
        }

        private async Task HandleVerifyAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var result = await service.VerifyAsync(
                context.RequireUser(),
                context.GetValueAsString(payload, "documentType"),
                context.GetValueAsInt(payload, "documentID"));

            context.SendResponse(requestID, true, result, null);
        }

        private static bool ParseBool(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }

            return string.Equals(value, "true", System.StringComparison.OrdinalIgnoreCase)
                || value == "1";
        }
    }
}
