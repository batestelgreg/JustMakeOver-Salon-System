using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Purchasing.Repositories
{
    // All SQL access for the new Purchasing workspace.
    public sealed class PurchasingRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public PurchasingRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory
                ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        public Dictionary<string, object> Load(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_PurchasingWorkspace_Load", connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                    .Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    // Names correspond to the SQL procedure's result order.
                    var names = new[]
                    {
                        "permissions", "replenishments", "requests",
                        "quotations", "suppliers", "orders", "budgets",
                        "receipts", "followups"
                    };

                    var result = new Dictionary<string, object>();

                    for (int index = 0; index < names.Length; index++)
                    {
                        result[names[index]] = ReadRows(reader);

                        if (index < names.Length - 1 && !reader.NextResult())
                            throw new InvalidOperationException(
                                "The Purchasing database migration is incomplete.");
                    }

                    return result;
                }
            }
        }

        public Dictionary<string, object> Execute(
            int actorUserID,
            string action,
            string payloadJson)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_PurchasingWorkspace_Action", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                    .Value = actorUserID;

                command.Parameters.Add("@Action", SqlDbType.VarChar, 30)
                    .Value = action;

                command.Parameters.Add("@Payload", SqlDbType.NVarChar, -1)
                    .Value = payloadJson;

                using (var reader = command.ExecuteReader())
                {
                    var rows = ReadRows(reader);

                    if (rows.Count == 0)
                        throw new InvalidOperationException(
                            "The Purchasing operation returned no result.");

                    return rows[0];
                }
            }
        }

        // Converts SQL rows to JSON-friendly records.
        // Dates use ISO text so JavaScript can display them consistently.
        private static List<Dictionary<string, object>> ReadRows(
            SqlDataReader reader)
        {
            var rows = new List<Dictionary<string, object>>();

            while (reader.Read())
            {
                var row = new Dictionary<string, object>();

                for (int index = 0; index < reader.FieldCount; index++)
                {
                    object value = reader.IsDBNull(index)
                        ? null
                        : reader.GetValue(index);

                    if (value is DateTime)
                    {
                        value = ((DateTime)value).ToString(
                            "yyyy-MM-ddTHH:mm:ss",
                            CultureInfo.InvariantCulture);
                    }

                    row[reader.GetName(index)] = value;
                }

                rows.Add(row);
            }

            return rows;
        }
    }
}