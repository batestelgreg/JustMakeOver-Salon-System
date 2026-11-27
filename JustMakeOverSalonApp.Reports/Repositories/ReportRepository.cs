using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Reports.Models;

namespace JustMakeOverSalonApp.Reports.Repositories
{
    // Kani nga repository kay READ-ONLY reporting queries ra (parameterized
    // usp_Report_* stored procedures). Walay operational mutations dinhi.
    public sealed class ReportRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public ReportRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory
                ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa tanang filter dropdown options ug
        // salon branding sa usa ra ka DB call.
        public Dictionary<string, object> GetFilterOptions(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Report_GetFilterOptions", connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    var context = SqlResultReader.ReadRow(reader)
                        ?? new Dictionary<string, object>();

                    var categories = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var items = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var suppliers = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var users = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var roles = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    return new Dictionary<string, object>
                    {
                        ["context"] = context,
                        ["categories"] = categories,
                        ["items"] = items,
                        ["suppliers"] = suppliers,
                        ["users"] = users,
                        ["roles"] = roles
                    };
                }
            }
        }

        // Kani nga method nag-execute sa matching usp_Report_* procedure
        // ug nagbasa sa RS1 (summary) + RS2 (detail rows).
        public Tuple<Dictionary<string, object>, List<Dictionary<string, object>>> RunReport(
            int actorUserID,
            string procedureName,
            ReportFilterRequest filter)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(procedureName, connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.CommandTimeout = 60;

                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ReportCode", SqlDbType.VarChar, 60).Value = filter.ReportCode;
                AddOptionalDate(command, "@DateFrom", filter.DateFrom);
                AddOptionalDate(command, "@DateTo", filter.DateTo);

                if (procedureName == "dbo.usp_Report_Inventory")
                {
                    AddOptionalDate(command, "@AsOfDate", filter.AsOfDate);
                    AddOptionalInt(command, "@ItemID", filter.ItemID);
                    AddOptionalInt(command, "@CategoryID", filter.CategoryID);
                    AddOptionalString(command, "@Status", filter.Status, 40);
                }
                else if (procedureName == "dbo.usp_Report_Purchasing"
                    || procedureName == "dbo.usp_Report_Receiving")
                {
                    AddOptionalInt(command, "@SupplierID", filter.SupplierID);
                    AddOptionalInt(command, "@ItemID", filter.ItemID);
                    AddOptionalInt(command, "@CategoryID", filter.CategoryID);
                    AddOptionalString(command, "@Status", filter.Status, 40);
                }
                else if (procedureName == "dbo.usp_Report_Requisition"
                    || procedureName == "dbo.usp_Report_Delivery")
                {
                    AddOptionalInt(command, "@ItemID", filter.ItemID);
                    AddOptionalInt(command, "@CategoryID", filter.CategoryID);
                    AddOptionalString(command, "@Status", filter.Status, 40);
                    AddOptionalInt(command, "@RequestorUserID", filter.RequestorUserID);
                    AddOptionalNVarChar(command, "@DepartmentRole", filter.DepartmentRole, 100);
                }
                else if (procedureName == "dbo.usp_Report_Replenishment")
                {
                    AddOptionalInt(command, "@ItemID", filter.ItemID);
                    AddOptionalInt(command, "@CategoryID", filter.CategoryID);
                    AddOptionalString(command, "@Status", filter.Status, 40);
                }
                else if (procedureName == "dbo.usp_Report_Audit")
                {
                    AddOptionalString(command, "@Status", filter.Status, 40);
                    AddOptionalInt(command, "@RequestorUserID", filter.RequestorUserID);
                }

                using (var reader = command.ExecuteReader())
                {
                    var summary = SqlResultReader.ReadRow(reader)
                        ?? new Dictionary<string, object>();

                    var rows = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    return Tuple.Create(summary, rows);
                }
            }
        }

        // Kani nga method nag-log sa print o export actions sa audit trail.
        public void LogAction(
            int actorUserID,
            string reportCode,
            string actionType,
            string filterSummary,
            int? rowCount)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Report_LogAction", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ReportCode", SqlDbType.VarChar, 60).Value = reportCode;
                command.Parameters.Add("@ActionType", SqlDbType.VarChar, 30).Value = actionType;
                command.Parameters.Add("@FilterSummary", SqlDbType.NVarChar, 1000).Value =
                    string.IsNullOrWhiteSpace(filterSummary) ? (object)DBNull.Value : filterSummary.Trim();
                command.Parameters.Add("@RowCount", SqlDbType.Int).Value =
                    rowCount.HasValue ? (object)rowCount.Value : DBNull.Value;

                command.ExecuteNonQuery();
            }
        }

        private static void AddOptionalDate(SqlCommand command, string name, DateTime? value)
        {
            command.Parameters.Add(name, SqlDbType.Date).Value =
                value.HasValue ? (object)value.Value.Date : DBNull.Value;
        }

        private static void AddOptionalInt(SqlCommand command, string name, int? value)
        {
            command.Parameters.Add(name, SqlDbType.Int).Value =
                value.HasValue && value.Value > 0 ? (object)value.Value : DBNull.Value;
        }

        private static void AddOptionalString(SqlCommand command, string name, string value, int maxLen)
        {
            command.Parameters.Add(name, SqlDbType.VarChar, maxLen).Value =
                string.IsNullOrWhiteSpace(value) ? (object)DBNull.Value : value.Trim();
        }

        private static void AddOptionalNVarChar(SqlCommand command, string name, string value, int maxLen)
        {
            command.Parameters.Add(name, SqlDbType.NVarChar, maxLen).Value =
                string.IsNullOrWhiteSpace(value) ? (object)DBNull.Value : value.Trim();
        }
    }
}
