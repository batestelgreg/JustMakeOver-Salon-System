using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
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

        // Kani nga method nagkuha sa TANANG data sa real PO print.
        // On-demand ni (print ra ang mo-call), so one DB call gihapon
        // ang page load. Usa ra ka proc ug usa ra ka result set.
        public Dictionary<string, object> GetPurchaseOrderPrint(
            int actorUserID,
            int poID)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_Purchasing_GetPurchaseOrderPrint",
                connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@POID",
                    SqlDbType.Int).Value = poID;

                using (var reader = command.ExecuteReader())
                {
                    return SqlResultReader.ReadRow(reader);
                }
            }
        }

        // Kani nga method nagkuha sa TANANG data sa Return Slip:
        // header + delivered/accepted/rejected line items.
        public Dictionary<string, object> GetReturnSlipPrint(
            int actorUserID,
            int drID)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_Purchasing_GetReturnSlip",
                connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@DRID",
                    SqlDbType.Int).Value = drID;

                using (var reader = command.ExecuteReader())
                {
                    var header = SqlResultReader.ReadRow(reader);

                    if (header == null)
                    {
                        return null;
                    }

                    var items = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    return new Dictionary<string, object>
                    {
                        ["header"] = header,
                        ["items"] = items
                    };
                }
            }
        }

        // Kani nga helper kay nag-delegate sa shared mapper aron usa ra
        // ang date/JSON conversion rules sa tibuok app.
        private static List<Dictionary<string, object>> ReadRows(
            SqlDataReader reader)
        {
            return SqlResultReader.ReadRows(reader);
        }
    }
}