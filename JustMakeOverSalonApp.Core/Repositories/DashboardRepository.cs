using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Core.Repositories
{
    // Kani nga repository kay para sa dashboard summary numbers.
    public sealed class DashboardRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public DashboardRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        public IDictionary<string, object> GetSummary(int userID)
        {
            // Kani nga procedure kay naghatag ug summary cards para sa dashboard.
            var summary = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.DashboardGetSummary, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@UserID", SqlDbType.Int).Value = userID;

                using (var reader = command.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        // Kani nga loop kay nagkuha sa tanang columns nga isinali sa procedure.
                        for (var index = 0; index < reader.FieldCount; index++)
                        {
                            summary[reader.GetName(index)] = reader.IsDBNull(index)
                                ? null
                                : reader.GetValue(index);
                        }
                    }
                }
            }

            return summary;
        }
    }
}
