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

        // Kani nga function kay kuhaon ang tanang user accounts para sa Users and Roles table.
        public IList<UserAccountRecord> GetAllUsers()
        {
            var users = new List<UserAccountRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            {
                var query = @"SELECT u.UserID, u.LastName, u.FirstName, u.MiddleName, 
                                     u.Username, u.PasswordHash, u.Email, u.IsActive, 
                                     u.FailedLoginAttempts, u.LockoutEnd, u.MustChangePassword, 
                                     u.RoleID, r.RoleName 
                              FROM USERS u 
                              INNER JOIN ROLES r ON u.RoleID = r.RoleID 
                              ORDER BY u.UserID DESC";

                using (var command = new SqlCommand(query, connection))
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        users.Add(MapUser(reader));
                    }
                }
            }
            return users;
        }

        // Kani nga method kay maghimo og bag-ong user gamit ang usp_User_Create.
        public void CreateUser(int actorUserID, string lastName, string firstName, string middleName,
                               string username, string passwordHash, string email, int roleID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_User_Create", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@LastName", SqlDbType.NVarChar, 50).Value = lastName;
                command.Parameters.Add("@FirstName", SqlDbType.NVarChar, 50).Value = firstName;
                command.Parameters.Add("@MiddleName", SqlDbType.NVarChar, 50).Value = (object)middleName ?? DBNull.Value;
                command.Parameters.Add("@Username", SqlDbType.NVarChar, 50).Value = username;
                command.Parameters.Add("@PasswordHash", SqlDbType.VarChar, 255).Value = passwordHash;
                command.Parameters.Add("@Email", SqlDbType.NVarChar, 254).Value = email;
                command.Parameters.Add("@RoleID", SqlDbType.Int).Value = roleID;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method kay mag-deactivate sa user gamit ang usp_User_Deactivate.
        public void DeactivateUser(int actorUserID, int targetUserID, string reason)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_User_Deactivate", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@TargetUserID", SqlDbType.Int).Value = targetUserID;
                command.Parameters.Add("@Reason", SqlDbType.NVarChar, 500).Value = (object)reason ?? DBNull.Value;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method kay mag-assign og role gamit ang usp_User_AssignRole.
        public void AssignRole(int actorUserID, int targetUserID, int newRoleID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_User_AssignRole", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@TargetUserID", SqlDbType.Int).Value = targetUserID;
                command.Parameters.Add("@NewRoleID", SqlDbType.Int).Value = newRoleID;

                command.ExecuteNonQuery();
            }
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