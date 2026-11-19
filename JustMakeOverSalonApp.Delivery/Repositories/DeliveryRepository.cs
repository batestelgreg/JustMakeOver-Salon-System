using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Delivery.Models;

namespace JustMakeOverSalonApp.Delivery.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Delivery module.
    // Kani nga file kay iya ra sa Delivery developer - walay laing mo-edit ani.
    // IMPORTANTE: ang stock deduction kay moagi lang sa usp_Delivery_Complete
    // (Stock Out nga may AR-#### reference) mao nga usa ra ang engine.
    public sealed class DeliveryRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public DeliveryRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa TANANG page data (allocated queue +
        // AR records) sa usa ra ka call aron usa lang ka connection ang
        // gamiton matag pag-load sa Delivery page.
        public DeliveryOverview LoadOverview(int actorUserID)
        {
            var overview = new DeliveryOverview
            {
                Allocated = new List<AllocatedRequisitionRecord>(),
                Deliveries = new List<DeliveryRecord>()
            };

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_GetOverview", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    // Kani nga resultset kay para sa allocated requisitions.
                    while (reader.Read())
                    {
                        overview.Allocated.Add(MapAllocated(reader));
                    }

                    // Kani nga NextResult kay para maabot ang AR records.
                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.Deliveries.Add(MapDelivery(reader));
                    }
                }
            }

            return overview;
        }

        // Kani nga method nag-generate sa AR (create path) ug mo-return
        // sa (DeliveryID, ARCode).
        public Tuple<int, string> GenerateAR(int actorUserID, int requisitionID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_GenerateAR", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@RequisitionID", SqlDbType.Int).Value = requisitionID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    return Tuple.Create(
                        Convert.ToInt32(reader["DeliveryID"]),
                        Convert.ToString(reader["ARCode"]));
                }
            }
        }

        // Kani nga method nag-mark issued sa AR (issue step sa Figure 10).
        public void MarkIssued(int actorUserID, int deliveryID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_MarkIssued", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-note discrepancy sa AR (NO branch sa diamond).
        public void NoteDiscrepancy(int actorUserID, int deliveryID, string notes)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_NoteDiscrepancy", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@Notes", SqlDbType.NVarChar, 1000).Value = notes;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-complete sa AR: e-sign + stock deduction +
        // requisition Fulfilled + requester notification (usa ka call).
        // Ang signature kay PNG data URL nga gikan sa signature pad.
        public void Complete(int actorUserID, int deliveryID, string signature)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_Complete", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@Signature", SqlDbType.NVarChar, -1).Value = signature;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-balik sa AR ngadto sa 'Generated' human sa
        // discrepancy correction (re-issue loop sa Figure 10).
        public void Reissue(int actorUserID, int deliveryID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_Reissue", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga mapper nag-convert sa row ngadto sa AllocatedRequisitionRecord.
        private static AllocatedRequisitionRecord MapAllocated(SqlDataReader reader)
        {
            return new AllocatedRequisitionRecord
            {
                RequisitionID = reader.GetInt32(0),
                RequestorName = reader.GetString(1),
                RequestDate = reader.GetDateTime(2),
                RequiredDate = reader.GetDateTime(3),
                Justification = reader.IsDBNull(4) ? null : reader.GetString(4),
                ItemsSummary = reader.IsDBNull(5) ? null : reader.GetString(5)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa DeliveryRecord.
        private static DeliveryRecord MapDelivery(SqlDataReader reader)
        {
            return new DeliveryRecord
            {
                DeliveryID = reader.GetInt32(0),
                ARCode = reader.GetString(1),
                RequisitionID = reader.GetInt32(2),
                RequestorName = reader.GetString(3),
                GeneratedDate = reader.GetDateTime(4),
                IssuedDate = reader.IsDBNull(5) ? (DateTime?)null : reader.GetDateTime(5),
                SignedDate = reader.IsDBNull(6) ? (DateTime?)null : reader.GetDateTime(6),
                SignedByName = reader.IsDBNull(7) ? null : reader.GetString(7),
                DiscrepancyNotes = reader.IsDBNull(8) ? null : reader.GetString(8),
                Status = reader.GetString(9),
                ItemsSummary = reader.IsDBNull(10) ? null : reader.GetString(10)
            };
        }
    }
}
