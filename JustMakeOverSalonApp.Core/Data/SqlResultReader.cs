using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Globalization;

namespace JustMakeOverSalonApp.Core.Data
{
    // Kani nga helper kay shared reader-to-JSON mapper para sa on-demand
    // print queries. Kini ra ang usa ka lugar nga nag-convert sa SQL rows
    // ngadto sa JSON-friendly dictionaries, so walay duplication sa matag
    // module. Ang DateTime kay string nga "yyyy-MM-ddTHH:mm:ss" aron
    // parehas ang format sa existing Purchasing workspace.
    public static class SqlResultReader
    {
        // Kani nga method nagbasa sa TANANG rows sa current result set.
        public static List<Dictionary<string, object>> ReadRows(
            SqlDataReader reader)
        {
            var rows = new List<Dictionary<string, object>>();

            while (reader.Read())
            {
                rows.Add(MapCurrentRow(reader));
            }

            return rows;
        }

        // Kani nga method nagbasa sa USA ka row (header) ug mo-return
        // ug null kung walay record.
        public static Dictionary<string, object> ReadRow(
            SqlDataReader reader)
        {
            return reader.Read()
                ? MapCurrentRow(reader)
                : null;
        }

        // Kani nga method nag-convert sa current row ngadto sa dictionary.
        private static Dictionary<string, object> MapCurrentRow(
            SqlDataReader reader)
        {
            var row = new Dictionary<string, object>();

            for (int index = 0; index < reader.FieldCount; index++)
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

            return row;
        }
    }
}
