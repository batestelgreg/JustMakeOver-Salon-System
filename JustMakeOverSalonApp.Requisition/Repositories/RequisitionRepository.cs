
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Requisition.Models;

namespace JustMakeOverSalonApp.Requisition.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Requisition module.
    public sealed class RequisitionRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public RequisitionRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Retrieve active items from the database.
        public List<ItemRecord> GetActiveItems()
        {
            var items = new List<ItemRecord>();

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    ItemID,
                    ItemCode,
                    ItemName,
                    CategoryID,
                    UnitOfMeasure,
                    ReorderPoint,
                    UnitPrice,
                    IsActive
                FROM ITEMS
                WHERE IsActive = 1
                ORDER BY ItemName ASC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var item = new ItemRecord
                    {
                        ItemID = reader.GetInt32(reader.GetOrdinal("ItemID")),
                        ItemCode = reader.GetString(reader.GetOrdinal("ItemCode")),
                        ItemName = reader.GetString(reader.GetOrdinal("ItemName")),
                        CategoryID = reader.GetInt32(reader.GetOrdinal("CategoryID")),
                        UnitOfMeasure = reader.GetString(reader.GetOrdinal("UnitOfMeasure")),
                        ReorderPoint = reader.GetInt32(reader.GetOrdinal("ReorderPoint")),
                        UnitPrice = reader.GetDecimal(reader.GetOrdinal("UnitPrice")),
                        IsActive = reader.GetBoolean(reader.GetOrdinal("IsActive"))
                    };

                    items.Add(item);
                }
            }

            return items;
        }


        // Retrieve stock levels of all active items.
        public List<StockLevel> GetStockLevels()
        {
            var stockLevels = new List<StockLevel>();

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    i.ItemID,
                    ISNULL(inv.QuantityOnHand, 0) AS QuantityOnHand,
                    ISNULL(inv.QuantityReserved, 0) AS QuantityReserved,
                    ISNULL(inv.QuantityAvailable, 0) AS QuantityAvailable
                FROM ITEMS AS i
                LEFT JOIN INVENTORY AS inv
                    ON i.ItemID = inv.ItemID
                WHERE i.IsActive = 1
                ORDER BY i.ItemName ASC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var stock = new StockLevel
                    {
                        ItemID = reader.GetInt32(reader.GetOrdinal("ItemID")),
                        QuantityOnHand = reader.GetInt32(reader.GetOrdinal("QuantityOnHand")),
                        QuantityReserved = reader.GetInt32(reader.GetOrdinal("QuantityReserved")),
                        QuantityAvailable = reader.GetInt32(reader.GetOrdinal("QuantityAvailable"))
                    };

                    stockLevels.Add(stock);
                }
            }

            return stockLevels;
        }


        // Save a requisition and its requested items.
        public int CreateRequisition(
            int requestorUserID,
            DateTime requiredDate,
            string justification,
            List<RequisitionDetailModel> items)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var transaction = connection.BeginTransaction())
            {
                try
                {
                    int requisitionID;

                    // Insert the requisition header.
                    using (var command = new SqlCommand(@"
                        INSERT INTO REQUISITIONS
                        (
                            RequestorUserID,
                            RequiredDate,
                            Justification
                        )
                        OUTPUT INSERTED.RequisitionID
                        VALUES
                        (
                            @RequestorUserID,
                            @RequiredDate,
                            @Justification
                        );
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@RequestorUserID", SqlDbType.Int)
                            .Value = requestorUserID;

                        command.Parameters.Add("@RequiredDate", SqlDbType.Date)
                            .Value = requiredDate.Date;

                        command.Parameters.Add("@Justification", SqlDbType.NVarChar, 500)
                            .Value = string.IsNullOrWhiteSpace(justification)
                                ? (object)DBNull.Value
                                : justification;

                        requisitionID = Convert.ToInt32(command.ExecuteScalar());
                    }

                    // Insert each requested item.
                    foreach (var item in items)
                    {
                        using (var command = new SqlCommand(@"
                            INSERT INTO REQUISITION_DETAILS
                            (
                                RequisitionID,
                                ItemID,
                                QuantityRequested
                            )
                            VALUES
                            (
                                @RequisitionID,
                                @ItemID,
                                @QuantityRequested
                            );
                        ", connection, transaction))
                        {
                            command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                                .Value = requisitionID;

                            command.Parameters.Add("@ItemID", SqlDbType.Int)
                                .Value = item.ItemID;

                            command.Parameters.Add("@QuantityRequested", SqlDbType.Int)
                                .Value = item.QuantityRequested;

                            command.ExecuteNonQuery();
                        }
                    }

                    // Save all database changes together.
                    transaction.Commit();

                    return requisitionID;
                }
                catch
                {
                    transaction.Rollback();
                    throw;
                }
            }
        }


    }
}
