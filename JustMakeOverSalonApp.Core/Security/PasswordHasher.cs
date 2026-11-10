using System;
using System.Security.Cryptography;

namespace JustMakeOverSalonApp.Core.Security
{
    // Kani nga class kay para sa password hashing gamit ang PBKDF2-SHA256.
    public static class PasswordHasher
    {
        private const int SaltSizeBytes = 32;
        private const int HashSizeBytes = 64;
        private const int DefaultIterations = 100000;
        private const string FormatPrefix = "PBKDF2-SHA256";

        // Kani nga method kay naghimo og bag-ong hash para sa bag-ong password.
        public static string HashPassword(string password)
        {
            if (string.IsNullOrWhiteSpace(password))
            {
                throw new ArgumentException("A password is required for hashing.", nameof(password));
            }

            var salt = new byte[SaltSizeBytes];
            using (var generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(salt);
            }

            var hash = DeriveHash(password, salt, DefaultIterations);
            return FormatPrefix + ":" + DefaultIterations + ":" +
                   Convert.ToBase64String(salt) + ":" + Convert.ToBase64String(hash);
        }

        // Kani nga method kay nag-verify sa password batok sa stored hash.
        public static bool VerifyPassword(string password, string storedHash)
        {
            if (string.IsNullOrWhiteSpace(password) || string.IsNullOrWhiteSpace(storedHash))
            {
                return false;
            }

            var parts = storedHash.Split(':');
            if (parts.Length != 4 || parts[0] != FormatPrefix)
            {
                return false;
            }

            int iterations;
            if (!int.TryParse(parts[1], out iterations) || iterations < 1 || iterations > 10000000)
            {
                return false;
            }

            byte[] salt;
            byte[] expected;
            try
            {
                salt = Convert.FromBase64String(parts[2]);
                expected = Convert.FromBase64String(parts[3]);
            }
            catch (FormatException)
            {
                return false;
            }

            var actual = DeriveHash(password, salt, iterations);
            return FixedTimeEquals(actual, expected);
        }

        private static byte[] DeriveHash(string password, byte[] salt, int iterations)
        {
            // Kani nga derivation kay compatible sa .NET Framework 4.8 PBKDF2 API.
            using (var derived = new Rfc2898DeriveBytes(password, salt, iterations, HashAlgorithmName.SHA256))
            {
                return derived.GetBytes(HashSizeBytes);
            }
        }

        private static bool FixedTimeEquals(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }

            // Kani nga comparison kay constant-time aron malikayan ang timing attacks.
            var difference = 0;
            for (var index = 0; index < left.Length; index++)
            {
                difference |= left[index] ^ right[index];
            }

            return difference == 0;
        }
    }
}
