using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Services
{
    // Kani nga service kay central validation ug permission guard para sa
    // digital signatures sa tanang internal business documents.
    public sealed class DocumentSignatureService
    {
        private static readonly HashSet<string> AllowedDocumentTypes =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "PURCHASE_ORDER",
                "RECEIVING_REPORT",
                "STOCK_CARD",
                "CORRECTION_REPORT",
                "REQUISITION",
                "REPLENISHMENT_REQUEST",
                "ACKNOWLEDGEMENT_RECEIPT",
                "DELIVERY_CHECK"
            };

        private readonly DocumentSignatureRepository repository;

        public DocumentSignatureService(
            DocumentSignatureRepository repository)
        {
            this.repository = repository
                ?? throw new ArgumentNullException(nameof(repository));
        }

        public Task<Dictionary<string, object>> GetAsync(
            CurrentUser actor,
            string documentType,
            int documentID)
        {
            RequireActor(actor);
            string normalizedType = ValidateDocumentType(documentType);
            ValidateDocumentID(documentID);

            return Task.FromResult(
                repository.Get(actor.UserID, normalizedType, documentID));
        }

        public Task<Dictionary<string, object>> SignAsync(
            CurrentUser actor,
            string documentType,
            int documentID,
            string stage,
            string signatureImage,
            bool confirmed)
        {
            RequireActor(actor);
            string normalizedType = ValidateDocumentType(documentType);
            ValidateDocumentID(documentID);

            if (string.IsNullOrWhiteSpace(stage))
            {
                throw new BusinessException("A valid signature stage is required.");
            }

            if (!confirmed)
            {
                throw new BusinessException(
                    "Please confirm your signature before saving.");
            }

            ValidateSignatureImage(signatureImage);

            return Task.FromResult(
                repository.Sign(
                    actor.UserID,
                    normalizedType,
                    documentID,
                    stage.Trim(),
                    signatureImage,
                    true));
        }

        public Task<Dictionary<string, object>> RevokeAsync(
            CurrentUser actor,
            long signatureID,
            string reason)
        {
            RequireActor(actor);

            if (!string.Equals(
                    actor.RoleName,
                    "Admin",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new BusinessException(
                    "Only an Admin can revoke a stored signature.");
            }

            if (signatureID <= 0)
            {
                throw new BusinessException(
                    "A valid signature record is required.");
            }

            if (string.IsNullOrWhiteSpace(reason))
            {
                throw new BusinessException(
                    "A revoke reason is required.");
            }

            if (reason.Trim().Length > 500)
            {
                throw new BusinessException(
                    "The revoke reason must be 500 characters or fewer.");
            }

            return Task.FromResult(
                repository.Revoke(actor.UserID, signatureID, reason.Trim()));
        }

        public Task<Dictionary<string, object>> VerifyAsync(
            CurrentUser actor,
            string documentType,
            int documentID)
        {
            RequireActor(actor);
            string normalizedType = ValidateDocumentType(documentType);
            ValidateDocumentID(documentID);

            return Task.FromResult(
                repository.Verify(actor.UserID, normalizedType, documentID));
        }

        // Kani nga helper kay shared validation nga magamit pud sa ubang modules.
        public static void ValidateSignatureImage(
            string signatureImage,
            string missingMessage = "A signature is required.")
        {
            if (string.IsNullOrWhiteSpace(signatureImage))
            {
                throw new BusinessException(missingMessage);
            }

            if (!signatureImage.StartsWith(
                    "data:image/",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new BusinessException(
                    "The signature image is not valid.");
            }

            if (signatureImage.Length > 2000000)
            {
                throw new BusinessException(
                    "The signature image is too large.");
            }
        }

        private static void RequireActor(CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException("Please sign in first.");
            }
        }

        private static string ValidateDocumentType(string documentType)
        {
            if (string.IsNullOrWhiteSpace(documentType))
            {
                throw new BusinessException("A document type is required.");
            }

            string normalized = documentType.Trim().ToUpperInvariant();
            if (!AllowedDocumentTypes.Contains(normalized))
            {
                throw new BusinessException(
                    "Digital signing is not configured for this document type.");
            }

            return normalized;
        }

        private static void ValidateDocumentID(int documentID)
        {
            if (documentID <= 0)
            {
                throw new BusinessException("A valid document ID is required.");
            }
        }
    }
}
