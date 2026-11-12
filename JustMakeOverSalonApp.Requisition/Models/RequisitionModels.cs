
using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Requisition.Models
{
    public class RequisitionModel
    {
        public int RequisitionID { get; set; }
        public int RequestorUserID { get; set; }
        public int? DepartmentHeadUserID { get; set; }
        public DateTime RequestDate { get; set; }
        public DateTime RequiredDate { get; set; }
        public string Justification { get; set; }
        public string Status { get; set; }
        public string RejectionReason { get; set; }

        public List<RequisitionDetailModel> Items { get; set; }
            = new List<RequisitionDetailModel>();
    }

    public class RequisitionDetailModel
    {
        public int RequisitionDetailID { get; set; }
        public int RequisitionID { get; set; }
        public int ItemID { get; set; }
        public int QuantityRequested { get; set; }
        public int? QuantityApproved { get; set; }
        public string Status { get; set; }
        public string ItemName { get; set; }
    }

    public class ItemRecord
    {
        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public int CategoryID { get; set; }
        public string UnitOfMeasure { get; set; }
        public int ReorderPoint { get; set; }
        public decimal UnitPrice { get; set; }
        public bool IsActive { get; set; }
    }

    public class StockLevel
    {
        public int ItemID { get; set; }
        public int QuantityOnHand { get; set; }
        public int QuantityReserved { get; set; }
        public int QuantityAvailable { get; set; }
    }
}
