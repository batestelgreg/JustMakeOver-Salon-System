using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Settings.Models
{
    // Kani nga model kay para sa usa ka unit of measure sa master list
    // (gikan sa UNIT_OF_MEASURES table - gamiton sa item form dropdown).
    public sealed class UomRecord
    {
        public int UomID { get; set; }
        public string UomName { get; set; }
        public bool IsActive { get; set; }
        public int ItemCount { get; set; }
    }

    // Kani nga model kay nagdala sa tanang page data sa usa ka call
    // (listahan sa units + kung naa ba'y active nga unit para sa dropdown).
    public sealed class UoMsOverview
    {
        public IList<UomRecord> UoMs { get; set; }
    }

    // Kani nga model kay para sa system preferences (key/value gikan
    // sa SYSTEM_SETTINGS table: branding + default restock days).
    public sealed class PreferencesData
    {
        public string SalonName { get; set; }
        public string SalonTagline { get; set; }
        public int DefaultRestockDays { get; set; }
    }
}
