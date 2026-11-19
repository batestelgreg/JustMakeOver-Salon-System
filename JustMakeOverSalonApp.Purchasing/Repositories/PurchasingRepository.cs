using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Purchasing.Repositories
{
    // Loads Purchasing records and executes Purchasing actions.
    public sealed class PurchasingRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public PurchasingRepository(
            ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory
                ?? throw new ArgumentNullException(
                    nameof(connectionFactory));
        }

        public Dictionary<string, object> Load(int actorUserID)
        {
            // Must match the result-set order returned by V012.
            string[] resultNames =
            {
                "permissions",
                "replenishments",
                "requests",
                "quotations",
                "suppliers",
                "orders",
                "budgets",
                "receipts",
                "followups"
            };

            var result = new Dictionary<string, object>();

            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_PurchasingWorkspace_Load",
                connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    for (int index = 0;
                        index < resultNames.Length;
                        index++)
                    {
                        if (index > 0 && !reader.NextResult())
                        {
                            throw new InvalidOperationException(
                                "The Purchasing workspace returned "
                                + "an incomplete set of records.");
                        }

                        result[resultNames[index]] = ReadRows(reader);
                    }
                }
            }

            return result;
        }

        public Dictionary<string, object> Execute(
            int actorUserID,
            string action,
            string payloadJson)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_PurchasingWorkspace_ActionWithDeliveryReference",
                connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@Action",
                    SqlDbType.VarChar,
                    30).Value = action;

                command.Parameters.Add(
                    "@Payload",
                    SqlDbType.NVarChar,
                    -1).Value = payloadJson;

                using (var reader = command.ExecuteReader())
                {
                    var rows = ReadRows(reader);

                    if (rows.Count == 0)
                    {
                        throw new InvalidOperationException(
                            "The Purchasing operation returned "
                            + "no confirmation.");
                    }

                    return rows[0];
                }
            }
        }

        // Converts SQL values into JSON-friendly records.
        private static List<Dictionary<string, object>> ReadRows(
            SqlDataReader reader)
        {
            var rows = new List<Dictionary<string, object>>();

            while (reader.Read())
            {
                var row = new Dictionary<string, object>();

                for (int index = 0;
                    index < reader.FieldCount;
                    index++)
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