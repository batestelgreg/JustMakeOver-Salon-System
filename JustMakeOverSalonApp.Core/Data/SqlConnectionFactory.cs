using System;
using System.Configuration;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Data
{
    // Kani nga interface kay para maka-himo og connection sa database.
    public interface ISqlConnectionFactory
    {
        SqlConnection CreateOpenConnection();
        string ConnectionString { get; }
    }

    // Diri naggikan ang connection string gikan sa App.config (o auto-detected LocalDB/SQLEXPRESS).
    public sealed class SqlConnectionFactory : ISqlConnectionFactory
    {
        private const string ConnectionName = "SalonDb";
        private static readonly object SyncRoot = new object();
        private static string resolvedConnectionString;

        public string ConnectionString { get; }

        public SqlConnectionFactory()
        {
            string raw;
            lock (SyncRoot)
            {
                raw = resolvedConnectionString;
            }

            if (string.IsNullOrWhiteSpace(raw))
            {
                raw = ReadConfiguredConnectionString();
            }

            // Kani nga tuning kay para dili mo-hang ang app kung busy ang SQL:
            // fast-fail nga 5 seconds ra, walay 15-second nga default timeout.
            var builder = new SqlConnectionStringBuilder(raw)
            {
                ConnectTimeout = 5,
                Pooling = true
            };

            ConnectionString = builder.ConnectionString;
        }

        public static string ReadConfiguredConnectionString()
        {
            var settings = ConfigurationManager.ConnectionStrings[ConnectionName];
            if (settings == null || string.IsNullOrWhiteSpace(settings.ConnectionString))
            {
                throw new ConfigurationErrorsException(
                    "The database connection is not configured. Add a connection string named '" +
                    ConnectionName + "' in the application configuration file.");
            }

            return settings.ConnectionString;
        }

        public static void SetResolvedConnectionString(string connectionString)
        {
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new ArgumentException("Connection string cannot be empty.", nameof(connectionString));
            }

            lock (SyncRoot)
            {
                resolvedConnectionString = connectionString;
            }
        }

        public SqlConnection CreateOpenConnection()
        {
            // Diri ibukas ang connection ug i-dispose ra sa tawag kung human na.
            var connection = new SqlConnection(ConnectionString);
            try
            {
                connection.Open();
                return connection;
            }
            catch (SqlException)
            {
                // Kani nga catch kay para ang connection timeout moabot nga
                // friendly nga English message, dili raw nga exception nga
                // mo-crash sa app. Gi-dispose ang connection sa wala pa throw.
                connection.Dispose();

                throw new BusinessException(
                    "The application could not reach the database. Please try again in a moment.");
            }
        }
    }
}
