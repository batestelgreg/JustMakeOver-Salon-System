using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Inventory.Models;

namespace JustMakeOverSalonApp.Inventory.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Inventory module.
    // Kani nga file kay iya ra sa Inventory developer - walay laing mo-edit ani.
    public sealed class InventoryRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public InventoryRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa tanang items ug live stock balances.
        public IList<InventoryItemRecord> LoadItems(int actorUserID)
        {
            var items = new List<InventoryItemRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetAll", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        items.Add(MapItem(reader));
                    }
                }
            }

            return items;
        }

        // Kani nga method nagkuha sa categories (active + counts) para sa
        // item form dropdown ug settings list.
        public IList<CategoryRecord> LoadCategories(int actorUserID)
        {
            var categories = new List<CategoryRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetCategories", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        categories.Add(MapCategory(reader));
                    }
                }
            }

            return categories;
        }

        // Kani nga method nag-generate sa sunod nga auto ItemCode.
        public string GetNextItemCode(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetNextItemCode", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    return reader.Read() ? reader.GetString(0) : string.Empty;
                }
            }
        }

        // Kani nga method nag-save sa category (create o rename + toggle).
        public int SaveCategory(int actorUserID, int? categoryID, string categoryName, bool isActive)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_SaveCategory", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@CategoryID", SqlDbType.Int).Value =
                    categoryID.HasValue ? (object)categoryID.Value : DBNull.Value;
                command.Parameters.Add("@CategoryName", SqlDbType.NVarChar, 100).Value = categoryName;
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;

                var result = command.ExecuteScalar();
                return Convert.ToInt32(result);
            }
        }

        // Kani nga method nag-himo ug bag-ong item ug mo-return sa ItemID + code.
        public CreateItemResult CreateItem(int actorUserID, InventoryItemRecord item, int initialQuantity)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_CreateItem", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemCode", SqlDbType.VarChar, 30).Value =
                    string.IsNullOrWhiteSpace(item.ItemCode) ? (object)DBNull.Value : item.ItemCode;
                command.Parameters.Add("@ItemName", SqlDbType.NVarChar, 200).Value = item.ItemName;
                command.Parameters.Add("@CategoryID", SqlDbType.Int).Value = item.CategoryID;
                command.Parameters.Add("@UnitOfMeasure", SqlDbType.NVarChar, 40).Value = item.UnitOfMeasure;
                command.Parameters.Add("@ReorderPoint", SqlDbType.Int).Value = item.ReorderPoint;
                command.Parameters.Add("@UnitPrice", SqlDbType.Decimal).Value = item.UnitPrice;
                command.Parameters["@UnitPrice"].Precision = 18;
                command.Parameters["@UnitPrice"].Scale = 2;
                command.Parameters.Add("@InitialQuantity", SqlDbType.Int).Value = initialQuantity;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        throw new InvalidOperationException(
                            "The item creation did not return a result.");
                    }

                    return new CreateItemResult
                    {
                        ItemID = reader.GetInt32(0),
                        ItemCode = reader.GetString(1)
                    };
                }
            }
        }

        // Kani nga method nag-update sa item details.
        public void UpdateItem(int actorUserID, InventoryItemRecord item)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_UpdateItem", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemID", SqlDbType.Int).Value = item.ItemID;
                command.Parameters.Add("@ItemCode", SqlDbType.VarChar, 30).Value = item.ItemCode;
                command.Parameters.Add("@ItemName", SqlDbType.NVarChar, 200).Value = item.ItemName;
                command.Parameters.Add("@CategoryID", SqlDbType.Int).Value = item.CategoryID;
                command.Parameters.Add("@UnitOfMeasure", SqlDbType.NVarChar, 40).Value = item.UnitOfMeasure;
                command.Parameters.Add("@ReorderPoint", SqlDbType.Int).Value = item.ReorderPoint;
                command.Parameters.Add("@UnitPrice", SqlDbType.Decimal).Value = item.UnitPrice;
                command.Parameters["@UnitPrice"].Precision = 18;
                command.Parameters["@UnitPrice"].Scale = 2;
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = item.IsActive;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-perform ug manual stock adjustment.
        public void AdjustStock(int actorUserID, int itemID, int quantityChange, string remarks)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_AdjustStock", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemID", SqlDbType.Int).Value = itemID;
                command.Parameters.Add("@QuantityChange", SqlDbType.Int).Value = quantityChange;
                command.Parameters.Add("@Remarks", SqlDbType.NVarChar, 1000).Value =
                    string.IsNullOrWhiteSpace(remarks) ? (object)DBNull.Value : remarks;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-issue ug stock (flowchart Figure 8.A).
        public IssueOutcome IssueStock(
            int actorUserID, int itemID, int quantityRequested,
            int? requisitionID, DateTime? estimatedRestockDate)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_IssueStock", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemID", SqlDbType.Int).Value = itemID;
                command.Parameters.Add("@QuantityRequested", SqlDbType.Int).Value = quantityRequested;
                command.Parameters.Add("@RequisitionID", SqlDbType.Int).Value =
                    requisitionID.HasValue ? (object)requisitionID.Value : DBNull.Value;
                command.Parameters.Add("@EstimatedRestockDate", SqlDbType.Date).Value =
                    estimatedRestockDate.HasValue ? (object)estimatedRestockDate.Value : DBNull.Value;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    return new IssueOutcome
                    {
                        Outcome = reader.GetString(0),
                        ReservedQuantity = reader.GetInt32(1),
                        ShortageQuantity = reader.GetInt32(2),
                        RepFID = reader.IsDBNull(3) ? (int?)null : reader.GetInt32(3)
                    };
                }
            }
        }

        // Kani nga method nag-record ug received stock (flowchart Figure 8.B).
        public void ReceiveStock(int actorUserID, int itemID, int quantityReceived, int? repFID, string remarks)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_ReceiveStock", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemID", SqlDbType.Int).Value = itemID;
                command.Parameters.Add("@QuantityReceived", SqlDbType.Int).Value = quantityReceived;
                command.Parameters.Add("@RepFID", SqlDbType.Int).Value =
                    repFID.HasValue ? (object)repFID.Value : DBNull.Value;
                command.Parameters.Add("@Remarks", SqlDbType.NVarChar, 1000).Value =
                    string.IsNullOrWhiteSpace(remarks) ? (object)DBNull.Value : remarks;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nagkuha sa recent stock movements.
        public IList<InventoryLogRecord> LoadLogs(int actorUserID)
        {
            var logs = new List<InventoryLogRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetLogs", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        logs.Add(MapLog(reader));
                    }
                }
            }

            return logs;
        }

        // Kani nga method nagkuha sa active reservations.
        public IList<ReservationRecord> LoadReservations(int actorUserID)
        {
            var reservations = new List<ReservationRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetReservations", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        reservations.Add(MapReservation(reader));
                    }
                }
            }

            return reservations;
        }

        // Kani nga method nagkuha sa replenishment requests (RepF).
        public IList<RepFRecord> LoadRepFs(int actorUserID)
        {
            var repFs = new List<RepFRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetRepFs", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        repFs.Add(MapRepF(reader));
                    }
                }
            }

            return repFs;
        }

        // Kani nga method nagkuha sa dashboard panel summary.
        public InventoryPanelSummary LoadPanel(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetPanel", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return new InventoryPanelSummary();
                    }

                    return new InventoryPanelSummary
                    {
                        TotalItems = reader.GetInt32(0),
                        LowStockItems = reader.GetInt32(1),
                        ReservedUnits = reader.GetInt32(2),
                        PendingRepFs = reader.GetInt32(3),
                        PartialReservations = reader.GetInt32(4),
                        RecentMovements = reader.GetInt32(5)
                    };
                }
            }
        }

        // Kani nga method nagkuha sa TANANG page data sa usa ra ka database call.
        // Kani nga optimization kay para ang page load kay usa lang ka connection
        // instead sa lima nga magkasunod-sunod nga calls.
        public InventoryOverview LoadOverview(int actorUserID)
        {
            var overview = new InventoryOverview
            {
                Items = new List<InventoryItemRecord>(),
                Categories = new List<CategoryRecord>(),
                Reservations = new List<ReservationRecord>(),
                RepFs = new List<RepFRecord>(),
                Logs = new List<InventoryLogRecord>()
            };

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Inventory_GetOverview", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    // Kani nga resultset kay para sa items.
                    while (reader.Read())
                    {
                        overview.Items.Add(MapItem(reader));
                    }

                    // Kani nga NextResult kay para maabot ang sunod nga resultset.
                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.Categories.Add(MapCategory(reader));
                    }

                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.Reservations.Add(MapReservation(reader));
                    }

                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.RepFs.Add(MapRepF(reader));
                    }

                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.Logs.Add(MapLog(reader));
                    }
                }
            }

            return overview;
        }

        // Kani nga mapper nag-convert sa row ngadto sa InventoryItemRecord.
        private static InventoryItemRecord MapItem(SqlDataReader reader)
        {
            return new InventoryItemRecord
            {
                ItemID = reader.GetInt32(0),
                ItemCode = reader.GetString(1),
                ItemName = reader.GetString(2),
                CategoryID = reader.GetInt32(3),
                CategoryName = reader.GetString(4),
                UnitOfMeasure = reader.GetString(5),
                ReorderPoint = reader.GetInt32(6),
                UnitPrice = reader.GetDecimal(7),
                IsActive = reader.GetBoolean(8),
                QuantityOnHand = reader.GetInt32(9),
                QuantityReserved = reader.GetInt32(10),
                QuantityAvailable = reader.GetInt32(11),
                IsLowStock = reader.GetBoolean(12)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa CategoryRecord.
        private static CategoryRecord MapCategory(SqlDataReader reader)
        {
            return new CategoryRecord
            {
                CategoryID = reader.GetInt32(0),
                CategoryName = reader.GetString(1),
                IsActive = reader.GetBoolean(2),
                ItemCount = reader.GetInt32(3)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa InventoryLogRecord.
        private static InventoryLogRecord MapLog(SqlDataReader reader)
        {
            return new InventoryLogRecord
            {
                LogID = reader.GetInt64(0),
                ItemName = reader.GetString(1),
                ItemCode = reader.GetString(2),
                TransactionType = reader.GetString(3),
                QuantityChange = reader.GetInt32(4),
                PreviousQuantity = reader.GetInt32(5),
                NewQuantity = reader.GetInt32(6),
                ReferenceType = reader.IsDBNull(7) ? null : reader.GetString(7),
                Remarks = reader.IsDBNull(9) ? null : reader.GetString(9),
                TransactionDate = reader.GetDateTime(10),
                UserName = reader.IsDBNull(11) ? null : reader.GetString(11),

                // Kani nga duha kay computed columns sa GetLogs (display format).
                Reference = reader.IsDBNull(12) ? null : reader.GetString(12),
                Source = reader.IsDBNull(13) ? null : reader.GetString(13)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa ReservationRecord.
        private static ReservationRecord MapReservation(SqlDataReader reader)
        {
            return new ReservationRecord
            {
                ReservationID = reader.GetInt32(0),
                RequisitionID = reader.GetInt32(2),
                ItemName = reader.GetString(3),
                ItemCode = reader.GetString(4),
                QuantityReserved = reader.GetInt32(5),
                ReservationDate = reader.GetDateTime(6),
                Status = reader.GetString(7),
                RequestorName = reader.IsDBNull(8) ? null : reader.GetString(8)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa RepFRecord.
        private static RepFRecord MapRepF(SqlDataReader reader)
        {
            return new RepFRecord
            {
                RepFID = reader.GetInt32(0),
                ItemID = reader.GetInt32(1),
                ItemName = reader.GetString(2),
                ItemCode = reader.GetString(3),
                QuantityNeeded = reader.GetInt32(4),
                DateGenerated = reader.GetDateTime(5),
                Status = reader.GetString(6)
            };
        }
    }
}
