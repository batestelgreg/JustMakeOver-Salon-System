using System.Collections.Generic;

namespace JustMakeOverSalonApp.Suppliers.Models
{
    // Kani nga model kay para sa usa ka supplier sa master list
    // (gikan sa SUPPLIERS table - may counts sa quotations ug POs
    // para makita dayon kung unsa nga suppliers ang naggamit na).
    public sealed class SupplierRecord
    {
        public int SupplierID { get; set; }
        public string SupplierCode { get; set; }
        public string SupplierName { get; set; }
        public string ContactPersonFirstName { get; set; }
        public string ContactPersonMiddleName { get; set; }
        public string ContactPersonLastName { get; set; }
        public string Phone { get; set; }
        public string Email { get; set; }
        public string Address { get; set; }
        public bool IsActive { get; set; }
        public int QuotationCount { get; set; }
        public int PurchaseOrderCount { get; set; }
    }

    // Kani nga model kay nagdala sa tanang page data sa usa ka call
    // (listahan sa suppliers sa usa ra ka database roundtrip).
    public sealed class SuppliersOverview
    {
        public IList<SupplierRecord> Suppliers { get; set; }
    }
}
