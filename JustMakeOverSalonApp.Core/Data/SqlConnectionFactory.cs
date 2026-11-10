using System;
using System.Configuration;
using System.Data.SqlClient;

namespace JustMakeOverSalonApp.Core.Data
{
    // Kani nga interface kay para maka-himo og connection sa database.
    public interface ISqlConnectionFactory
    {
        SqlConnection CreateOpenConnection();
        string ConnectionString { get; }
    }

    // Diri naggikan ang connection string gikan sa App.config sa desktop project.
    public sealed class SqlConnectionFactory : ISqlConnectionFactory
    {
        private const string ConnectionName = "SalonDb";

        public string ConnectionString { get; }

        public SqlConnectionFactory()
        {
            // Kani nga connection string kinahanglan naa sa App.config aron molarga ang app.
            var settings = ConfigurationManager.ConnectionStrings[ConnectionName];
            if (settings == null || string.IsNullOrWhiteSpace(settings.ConnectionString))
            {
                throw new ConfigurationErrorsException(
                    "The database connection is not configured. Add a connection string named '" +
                    ConnectionName + "' in the application configuration file.");
            }

            ConnectionString = settings.ConnectionString;
        }

        public SqlConnection CreateOpenConnection()
        {
            // Diri ibukas ang connection ug i-dispose ra sa tawag kung human na.
            var connection = new SqlConnection(ConnectionString);
            connection.Open();
            return connection;
        }
    }
}
