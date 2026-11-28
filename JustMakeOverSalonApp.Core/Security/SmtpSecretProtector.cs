using System;
using System.Security.Cryptography;
using System.Text;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Security
{
    // Encrypts and decrypts SMTP secrets (Google App Password) using Windows DPAPI
    // so credentials stored in the database are never readable as plaintext.
    public static class SmtpSecretProtector
    {
        private const string DpapiPrefix = "dpapi:";

        private static readonly byte[] Entropy =
            Encoding.UTF8.GetBytes("JustMakeOverSalonApp.SmtpSecret.v1");

        public static string Protect(string plainSecret)
        {
            string normalized = NormalizeAppPassword(plainSecret);
            if (string.IsNullOrEmpty(normalized))
            {
                return null;
            }

            byte[] plainBytes = Encoding.UTF8.GetBytes(normalized);
            byte[] protectedBytes = ProtectedData.Protect(
                plainBytes,
                Entropy,
                DataProtectionScope.LocalMachine);

            return DpapiPrefix + Convert.ToBase64String(protectedBytes);
        }

        public static string Unprotect(string storedValue)
        {
            if (string.IsNullOrWhiteSpace(storedValue))
            {
                return string.Empty;
            }

            string trimmed = storedValue.Trim();
            if (!trimmed.StartsWith(DpapiPrefix, StringComparison.Ordinal))
            {
                return NormalizeAppPassword(trimmed);
            }

            try
            {
                string base64 = trimmed.Substring(DpapiPrefix.Length);
                byte[] protectedBytes = Convert.FromBase64String(base64);
                byte[] plainBytes = ProtectedData.Unprotect(
                    protectedBytes,
                    Entropy,
                    DataProtectionScope.LocalMachine);

                return NormalizeAppPassword(Encoding.UTF8.GetString(plainBytes));
            }
            catch (Exception ex) when (ex is CryptographicException || ex is FormatException)
            {
                throw new BusinessException(
                    "The saved SMTP App Password could not be decrypted on this computer. Please ask an Administrator to re-enter it under Settings -> Official Salon Email.");
            }
        }

        public static string NormalizeAppPassword(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                return string.Empty;
            }

            return raw.Replace(" ", string.Empty).Trim();
        }
    }
}
