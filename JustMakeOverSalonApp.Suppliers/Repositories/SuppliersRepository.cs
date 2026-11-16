using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Suppliers.Models;

namespace JustMakeOverSalonApp.Suppliers.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Suppliers module.
    // Kani nga file kay iya ra sa Suppliers developer - walay laing mo-edit ani.
    public sealed class SuppliersRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public SuppliersRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa suppliers master list (nga may
        // quotation ug PO count kada supplier) sa usa ra ka call.
        public SuppliersOverview LoadSuppliers(int actorUserID)
        {
            var suppliers = new List<SupplierRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Suppliers_GetAll", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        suppliers.Add(new SupplierRecord
                        {
                            SupplierID = reader.GetInt32(0),
                            SupplierCode = reader.GetString(1),
                            SupplierName = reader.GetString(2),
                            ContactPersonFirstName = reader.IsDBNull(3) ? null : reader.GetString(3),
                            ContactPersonMiddleName = reader.IsDBNull(4) ? null : reader.GetString(4),
                            ContactPersonLastName = reader.IsDBNull(5) ? null : reader.GetString(5),
                            Phone = reader.IsDBNull(6) ? null : reader.GetString(6),
                            Email = reader.IsDBNull(7) ? null : reader.GetString(7),
                            Address = reader.IsDBNull(8) ? null : reader.GetString(8),
                            IsActive = reader.GetBoolean(9),
                            QuotationCount = reader.GetInt32(10),
                            PurchaseOrderCount = reader.GetInt32(11)
                        });
                    }
                }
            }

            return new SuppliersOverview { Suppliers = suppliers };
        }

        // Kani nga method nag-save sa supplier (create o update).
        // Ang proc mo-throw kung duplicate nga name o invalid data.
        // Create path: mod return sa (SupplierID, SupplierCode).
        public Tuple<int, string> SaveSupplier(
            int actorUserID,
            int? supplierID,
            string supplierName,
            string contactFirstName,
            string contactMiddleName,
            string contactLastName,
            string phone,
            string email,
            string address,
            bool? isActive)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Suppliers_Save", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@SupplierID", SqlDbType.Int).Value =
                    supplierID.HasValue ? (object)supplierID.Value : DBNull.Value;
                command.Parameters.Add("@SupplierName", SqlDbType.NVarChar, 200).Value =
                    string.IsNullOrWhiteSpace(supplierName) ? (object)DBNull.Value : supplierName.Trim();
                command.Parameters.Add("@ContactPersonFirstName", SqlDbType.NVarChar, 100).Value =
                    string.IsNullOrWhiteSpace(contactFirstName) ? (object)DBNull.Value : contactFirstName.Trim();
                command.Parameters.Add("@ContactPersonMiddleName", SqlDbType.NVarChar, 100).Value =
                    string.IsNullOrWhiteSpace(contactMiddleName) ? (object)DBNull.Value : contactMiddleName.Trim();
                command.Parameters.Add("@ContactPersonLastName", SqlDbType.NVarChar, 100).Value =
                    string.IsNullOrWhiteSpace(contactLastName) ? (object)DBNull.Value : contactLastName.Trim();
                command.Parameters.Add("@Phone", SqlDbType.VarChar, 20).Value =
                    string.IsNullOrWhiteSpace(phone) ? (object)DBNull.Value : phone.Trim();
                command.Parameters.Add("@Email", SqlDbType.NVarChar, 508).Value =
                    string.IsNullOrWhiteSpace(email) ? (object)DBNull.Value : email.Trim();
                command.Parameters.Add("@Address", SqlDbType.NVarChar, 1000).Value =
                    string.IsNullOrWhiteSpace(address) ? (object)DBNull.Value : address.Trim();
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value =
                    isActive.HasValue ? (object)isActive.Value : DBNull.Value;

                // Kani nga execute kay para sa create path (mod return sa
                // SupplierID + SupplierCode); ang update path kay walay
                // result set, so null ang result.
                using (var reader = command.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        return Tuple.Create(
                            Convert.ToInt32(reader["SupplierID"]),
                            Convert.ToString(reader["SupplierCode"]));
                    }
                }

                return null;
            }
        }
    }
}
