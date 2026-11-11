using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;

namespace JustMakeOverSalonApp.Core.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa user accounts ug user management.
    public sealed class UserRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public UserRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        }

        public UserAccountRecord GetUserByUsername(string username)
        {
            // Kani nga procedure kay nagkuha sa account details base sa username.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.LoginGetUser, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@Username", SqlDbType.NVarChar, 50).Value = username;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    return MapUser(reader);
                }
            }
        }

        public void RecordFailedLogin(string username)
        {
            // Kani nga procedure kay nagtaas sa failed attempts ug nag-lock kung moabot sa lima.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.LoginFailed, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@Username", SqlDbType.NVarChar, 50).Value = username;
                command.ExecuteNonQuery();
            }
        }

        public void RecordSuccessfulLogin(int userID)
        {
            // Kani nga procedure kay nag-reset sa failed attempts ug nag-log sa LastLogin.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.LoginSucceeded, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@UserID", SqlDbType.Int).Value = userID;
                command.ExecuteNonQuery();
            }
        }

        public void ChangePasswordHash(int userID, string newHash)
        {
            // Kani nga procedure kay nag-update sa password hash ug MustChangePassword flag.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserChangePassword, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@UserID", SqlDbType.Int).Value = userID;
                command.Parameters.Add("@NewHash", SqlDbType.VarChar, 255).Value = newHash;
                command.ExecuteNonQuery();
            }
        }

        public IList<string> GetPermissions(int userID)
        {
            // Kani nga procedure kay nagkuha sa role ug permissions sa active user.
            var permissions = new List<string>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.GetUserPermissions, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@UserID", SqlDbType.Int).Value = userID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        var code = reader["PermissionCode"] as string;
                        if (!string.IsNullOrWhiteSpace(code))
                        {
                            permissions.Add(code);
                        }
                    }
                }
            }

            return permissions;
        }

        private static UserAccountRecord MapUser(IDataRecord row)
        {
            // Kani nga mapping kay nag-convert sa reader row ngadto sa model.
            return new UserAccountRecord
            {
                UserID = row.GetInt32(row.GetOrdinal("UserID")),
                LastName = row["LastName"] as string,
                FirstName = row["FirstName"] as string,
                MiddleName = row["MiddleName"] as string,
                Username = row["Username"] as string,
                PasswordHash = row["PasswordHash"] as string,
                Email = row["Email"] as string,
                IsActive = Convert.ToBoolean(row["IsActive"]),
                FailedLoginAttempts = Convert.ToInt32(row["FailedLoginAttempts"]),
                LockoutEnd = row["LockoutEnd"] == DBNull.Value
                    ? (DateTime?)null
                    : Convert.ToDateTime(row["LockoutEnd"]),
                MustChangePassword = Convert.ToBoolean(row["MustChangePassword"]),
                RoleID = Convert.ToInt32(row["RoleID"]),
                RoleName = row["RoleName"] as string
            };
        }
    }
}