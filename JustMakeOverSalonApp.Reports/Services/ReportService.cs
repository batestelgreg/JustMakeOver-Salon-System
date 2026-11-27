using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Reports.Models;
using JustMakeOverSalonApp.Reports.Repositories;

namespace JustMakeOverSalonApp.Reports.Services
{
    // Kani nga service kay central guard sa Report Module: permission checks
    // (reports.view, reports.export, reports.audit), report allowlist mapping,
    // date validation, ug audit logging. Strictly read-only.
    public sealed class ReportService
    {
        private static readonly Dictionary<string, string> ReportProcedureMap =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                // Inventory
                ["INV_STOCK_CARD"] = "dbo.usp_Report_Inventory",
                ["INV_MOVEMENT_LEDGER"] = "dbo.usp_Report_Inventory",
                ["INV_STOCK_POSITION"] = "dbo.usp_Report_Inventory",
                ["INV_LOW_STOCK"] = "dbo.usp_Report_Inventory",
                ["INV_ADJUSTMENTS"] = "dbo.usp_Report_Inventory",

                // Purchasing
                ["PUR_PO_REGISTER"] = "dbo.usp_Report_Purchasing",
                ["PUR_PO_OUTSTANDING"] = "dbo.usp_Report_Purchasing",
                ["PUR_SUPPLIER_PERF"] = "dbo.usp_Report_Purchasing",
                ["PUR_RETURN_SLIPS"] = "dbo.usp_Report_Purchasing",
                ["PUR_QUOTATION_HISTORY"] = "dbo.usp_Report_Purchasing",

                // Receiving
                ["REC_RR_REGISTER"] = "dbo.usp_Report_Receiving",
                ["REC_RR_VS_PO"] = "dbo.usp_Report_Receiving",
                ["REC_REJECTED_ITEMS"] = "dbo.usp_Report_Receiving",
                ["REC_MANUAL_RECEIPTS"] = "dbo.usp_Report_Receiving",

                // Requisition
                ["REQ_REGISTER"] = "dbo.usp_Report_Requisition",
                ["REQ_STATUS_SUMMARY"] = "dbo.usp_Report_Requisition",
                ["REQ_FULFILLMENT_RATE"] = "dbo.usp_Report_Requisition",
                ["REQ_REQUESTOR_USAGE"] = "dbo.usp_Report_Requisition",

                // Delivery
                ["DEL_AR_REGISTER"] = "dbo.usp_Report_Delivery",
                ["DEL_ISSUED_COMPLETED"] = "dbo.usp_Report_Delivery",
                ["DEL_DISCREPANCY_CORRECTION"] = "dbo.usp_Report_Delivery",
                ["DEL_SIGNATURE_HISTORY"] = "dbo.usp_Report_Delivery",

                // Replenishment
                ["REPF_REGISTER"] = "dbo.usp_Report_Replenishment",
                ["REPF_STATUS_TRACKING"] = "dbo.usp_Report_Replenishment",

                // Audit / Security
                ["AUD_PRINT_SIGNATURE"] = "dbo.usp_Report_Audit",
                ["AUD_CORRECTION_HISTORY"] = "dbo.usp_Report_Audit",
                ["AUD_USER_ACTIVITY"] = "dbo.usp_Report_Audit"
            };

        private static readonly HashSet<string> AllowedLogActions =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "PRINT",
                "EXPORT_CSV",
                "EXPORT_EXCEL",
                "DOC_PRINT"
            };

        private readonly ReportRepository repository;

        public ReportService(ReportRepository repository)
        {
            this.repository = repository
                ?? throw new ArgumentNullException(nameof(repository));
        }

        public Task<Dictionary<string, object>> LoadFilterOptionsAsync(CurrentUser actor)
        {
            RequireActor(actor);
            actor.RequirePermission(PermissionCodes.ReportsView);

            return Task.FromResult(repository.GetFilterOptions(actor.UserID));
        }

        public Task<ReportRunResult> RunReportAsync(
            CurrentUser actor,
            ReportFilterRequest filter)
        {
            RequireActor(actor);
            actor.RequirePermission(PermissionCodes.ReportsView);

            if (filter == null || string.IsNullOrWhiteSpace(filter.ReportCode))
            {
                throw new BusinessException("Please select a report to generate.");
            }

            string code = filter.ReportCode.Trim().ToUpperInvariant();
            if (!ReportProcedureMap.TryGetValue(code, out string procedureName))
            {
                throw new BusinessException("The selected report is not supported.");
            }

            if (procedureName == "dbo.usp_Report_Audit")
            {
                actor.RequirePermission(PermissionCodes.ReportsAudit);
            }

            if (filter.DateFrom.HasValue
                && filter.DateTo.HasValue
                && filter.DateFrom.Value.Date > filter.DateTo.Value.Date)
            {
                throw new BusinessException(
                    "The start date cannot be later than the end date.");
            }

            filter.ReportCode = code;

            var data = repository.RunReport(actor.UserID, procedureName, filter);

            return Task.FromResult(new ReportRunResult
            {
                ReportCode = code,
                GeneratedBy = string.IsNullOrWhiteSpace(actor.FullName)
                    ? actor.Username
                    : actor.FullName,
                GeneratedRole = actor.RoleName,
                GeneratedAt = DateTime.Now.ToString(
                    "yyyy-MM-ddTHH:mm:ss",
                    CultureInfo.InvariantCulture),
                Summary = data.Item1,
                Rows = data.Item2
            });
        }

        public Task LogExportOrPrintAsync(
            CurrentUser actor,
            string reportCode,
            string actionType,
            string filterSummary,
            int? rowCount)
        {
            RequireActor(actor);

            if (string.IsNullOrWhiteSpace(reportCode))
            {
                throw new BusinessException("A report code is required.");
            }

            string normalizedAction = (actionType ?? string.Empty).Trim().ToUpperInvariant();
            if (!AllowedLogActions.Contains(normalizedAction))
            {
                throw new BusinessException("Invalid report audit action.");
            }

            if (normalizedAction == "EXPORT_CSV" || normalizedAction == "EXPORT_EXCEL")
            {
                actor.RequirePermission(PermissionCodes.ReportsExport);
            }
            else if (normalizedAction == "PRINT")
            {
                actor.RequirePermission(PermissionCodes.ReportsView);
            }

            repository.LogAction(
                actor.UserID,
                reportCode.Trim().ToUpperInvariant(),
                normalizedAction,
                filterSummary,
                rowCount);

            return Task.CompletedTask;
        }

        private static void RequireActor(CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException("Please sign in before accessing Reports.");
            }
        }
    }
}
