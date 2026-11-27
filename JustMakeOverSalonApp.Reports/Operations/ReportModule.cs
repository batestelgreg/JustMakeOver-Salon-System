using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Reports.Models;
using JustMakeOverSalonApp.Reports.Repositories;
using JustMakeOverSalonApp.Reports.Services;

namespace JustMakeOverSalonApp.Reports.Operations
{
    // Kani nga module kay nag-register sa tanang read-only Report Module
    // bridge operations (ReportInit, ReportRun, ReportLogAction).
    public sealed class ReportModule : IModuleOperations
    {
        private IOperationContext context;
        private ReportService service;

        public void RegisterOperations(
            OperationRegistry registry,
            IOperationContext context)
        {
            this.context = context;
            service = new ReportService(
                new ReportRepository(new SqlConnectionFactory()));

            registry.Register("ReportInit", HandleInitAsync);
            registry.Register("ReportRun", HandleRunAsync);
            registry.Register("ReportLogAction", HandleLogActionAsync);
        }

        private async Task HandleInitAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var actor = context.RequireUser();
            var options = await service.LoadFilterOptionsAsync(actor);
            context.SendResponse(requestID, true, options, null);
        }

        private async Task HandleRunAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var actor = context.RequireUser();

            var filter = new ReportFilterRequest
            {
                ReportCode = context.GetValueAsString(payload, "reportCode"),
                DateFrom = ParseNullableDate(context.GetValueAsString(payload, "dateFrom")),
                DateTo = ParseNullableDate(context.GetValueAsString(payload, "dateTo")),
                AsOfDate = ParseNullableDate(context.GetValueAsString(payload, "asOfDate")),
                SupplierID = ParseNullableInt(context.GetValueAsString(payload, "supplierID")),
                ItemID = ParseNullableInt(context.GetValueAsString(payload, "itemID")),
                CategoryID = ParseNullableInt(context.GetValueAsString(payload, "categoryID")),
                Status = context.GetValueAsString(payload, "status"),
                RequestorUserID = ParseNullableInt(context.GetValueAsString(payload, "requestorUserID")),
                DepartmentRole = context.GetValueAsString(payload, "departmentRole")
            };

            var result = await service.RunReportAsync(actor, filter);

            context.SendResponse(requestID, true, new
            {
                reportCode = result.ReportCode,
                generatedBy = result.GeneratedBy,
                generatedRole = result.GeneratedRole,
                generatedAt = result.GeneratedAt,
                summary = result.Summary,
                rows = result.Rows
            }, null);
        }

        private async Task HandleLogActionAsync(
            Dictionary<string, object> payload,
            string requestID)
        {
            var actor = context.RequireUser();

            await service.LogExportOrPrintAsync(
                actor,
                context.GetValueAsString(payload, "reportCode"),
                context.GetValueAsString(payload, "actionType"),
                context.GetValueAsString(payload, "filterSummary"),
                ParseNullableInt(context.GetValueAsString(payload, "rowCount")));

            context.SendResponse(requestID, true, new { logged = true }, null);
        }

        private static int? ParseNullableInt(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return null;
            }

            return int.TryParse(value, out int parsed) && parsed > 0
                ? (int?)parsed
                : null;
        }

        private static DateTime? ParseNullableDate(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return null;
            }

            return DateTime.TryParse(value, out DateTime parsed)
                ? (DateTime?)parsed.Date
                : null;
        }
    }
}
