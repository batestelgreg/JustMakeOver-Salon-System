using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Settings.Models;

namespace JustMakeOverSalonApp.Settings.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Settings module.
    // Kani nga file kay iya ra sa Settings developer - walay laing mo-edit ani.
    public sealed class SettingsRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public SettingsRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa unit of measures master list
        // (nga may item count kada unit) sa usa ra ka database call.
        public UoMsOverview LoadUoMs(int actorUserID)
        {
            var uoMs = new List<UomRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Settings_GetUoMs", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        uoMs.Add(new UomRecord
                        {
                            UomID = reader.GetInt32(0),
                            UomName = reader.GetString(1),
                            IsActive = reader.GetBoolean(2),
                            ItemCount = reader.GetInt32(3)
                        });
                    }
                }
            }

            return new UoMsOverview { UoMs = uoMs };
        }

        // Kani nga method nag-save sa unit of measure (create o update).
        // Ang proc mo-throw kung duplicate o gigamit pa sa items.
        public int SaveUom(int actorUserID, int? uomID, string uomName, bool? isActive)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Settings_SaveUom", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@UomID", SqlDbType.Int).Value =
                    uomID.HasValue ? (object)uomID.Value : DBNull.Value;
                command.Parameters.Add("@UomName", SqlDbType.VarChar, 20).Value =
                    string.IsNullOrWhiteSpace(uomName) ? (object)DBNull.Value : uomName.Trim();
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value =
                    isActive.HasValue ? (object)isActive.Value : DBNull.Value;

                var result = command.ExecuteScalar();
                return result == null || result is DBNull ? 0 : Convert.ToInt32(result);
            }
        }

        // Kani nga method nagkuha sa system preferences (key/value rows)
        // ug gi-convert ngadto sa typed nga PreferencesData.
        public PreferencesData LoadPreferences(int actorUserID)
        {
            var preferences = new PreferencesData();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Settings_GetPreferences", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        var key = reader.GetString(0);
                        var value = reader.GetString(1);

                        if (key == "SalonName")
                        {
                            preferences.SalonName = value;
                        }
                        else if (key == "SalonTagline")
                        {
                            preferences.SalonTagline = value;
                        }
                        else if (key == "DefaultRestockDays")
                        {
                            preferences.DefaultRestockDays =
                                int.TryParse(value, out var days) ? days : 7;
                        }
                    }
                }
            }

            return preferences;
        }

        // Kani nga method nag-save sa system preferences (upsert sa proc).
        public void SavePreferences(
            int actorUserID, string salonName, string salonTagline, int defaultRestockDays)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Settings_SavePreferences", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@SalonName", SqlDbType.NVarChar, 100).Value = salonName;
                command.Parameters.Add("@SalonTagline", SqlDbType.NVarChar, 60).Value = salonTagline;
                command.Parameters.Add("@DefaultRestockDays", SqlDbType.Int).Value = defaultRestockDays;

                command.ExecuteNonQuery();
            }
        }
    }
}
