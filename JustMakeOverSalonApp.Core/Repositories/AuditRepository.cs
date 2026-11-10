using System;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Repositories
{
    // Kani nga repository kay para sa user audit logs.
    public sealed class AuditRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public AuditRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        public void LogAction(int? actorUserID, string actionType, string description, string ipAddress)
        {
            // Kani nga procedure kay nag-sulat sa audit log para sa importanteng actions.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.AuditLogAction, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value =
                    (object)actorUserID ?? DBNull.Value;
                command.Parameters.Add("@ActionType", SqlDbType.VarChar, 50).Value = actionType;
                command.Parameters.Add("@Description", SqlDbType.NVarChar, 500).Value =
                    (object)description ?? DBNull.Value;
                command.Parameters.Add("@IPAddress", SqlDbType.VarChar, 45).Value =
                    (object)ipAddress ?? DBNull.Value;

                command.ExecuteNonQuery();
            }
        }
    }
}
