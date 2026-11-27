using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Reports.Models
{
    // Kani nga request model kay para sa tanang common filters sa Report Module.
    // Walay SQL nga gikan sa frontend; tanan kay typed parameters.
    public sealed class ReportFilterRequest
    {
        public string ReportCode { get; set; }
        public DateTime? DateFrom { get; set; }
        public DateTime? DateTo { get; set; }
        public DateTime? AsOfDate { get; set; }
        public int? SupplierID { get; set; }
        public int? ItemID { get; set; }
        public int? CategoryID { get; set; }
        public string Status { get; set; }
        public int? RequestorUserID { get; set; }
        public string DepartmentRole { get; set; }
    }

    // Kani nga result kay parehas ang shape sa tanang reports:
    // header/summary KPIs + detail rows + generation metadata.
    public sealed class ReportRunResult
    {
        public string ReportCode { get; set; }
        public string GeneratedBy { get; set; }
        public string GeneratedRole { get; set; }
        public string GeneratedAt { get; set; }
        public Dictionary<string, object> Summary { get; set; }
        public List<Dictionary<string, object>> Rows { get; set; }
    }
}
