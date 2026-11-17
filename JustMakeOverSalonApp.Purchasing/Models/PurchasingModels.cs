// Kani nga folder kay para sa mga models sa Purchasing module
// (pananglitan: ItemRecord, StockLevel, ug uban pa).
// Ang kada model kay iya ra sa Purchasing developer.

using System;

namespace JustMakeOverSalonApp.Purchasing.Models
{
    public sealed class ReplenishmentRequestRecord
    {
        public int RepFID { get; set; }
        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public int QuantityNeeded { get; set; }
        public DateTime DateGenerated { get; set; }
        public string Status { get; set; }
    }

    public sealed class PurchaseRequestRecord
    {
        public int PRID { get; set; }
        public int RepFID { get; set; }
        public int CreatedByUserID { get; set; }
        public DateTime DateCreated { get; set; }
        public string Status { get; set; }

        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public int QuantityNeeded { get; set; }
    }

    public sealed class SupplierQuotationRecord
    {
        public int QuotationID { get; set; }
        public int PRID { get; set; }
        public int SupplierID { get; set; }
        public string SupplierName { get; set; }
        public decimal QuotedPrice { get; set; }
        public bool IsRecommended { get; set; }
        public DateTime DateQuoted { get; set; }
    }

    public sealed class PurchaseOrderRecord
    {
        public int POID { get; set; }
        public int PRID { get; set; }
        public int SupplierID { get; set; }
        public string SupplierName { get; set; }
        public int? ApprovedByUserID { get; set; }
        public int QuantityOrdered { get; set; }
        public decimal UnitPrice { get; set; }
        public decimal TotalAmount { get; set; }
        public string Status { get; set; }
        public DateTime DateIssued { get; set; }
    }
}