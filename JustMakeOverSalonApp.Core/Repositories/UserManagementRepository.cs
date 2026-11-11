using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;

namespace JustMakeOverSalonApp.Core.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa user ug role management.
    public sealed class UserManagementRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public UserManagementRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        public IList<UserListItem> GetUsers(int actorUserID)
        {
            // Kani nga procedure nagkuha sa tanang user accounts nga may role details.
            var users = new List<UserListItem>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UsersGetAll, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        users.Add(MapUserListItem(reader));
                    }
                }
            }

            return users;
        }

        public void UpdateUserDetails(
            int actorUserID,
            int targetUserID,
            string lastName,
            string firstName,
            string middleName,
            string email,
            int roleID)
        {
            // Kani nga procedure nag-update sa basic details ug role sa user.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserUpdateDetails, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@TargetUserID", SqlDbType.Int).Value = targetUserID;
                command.Parameters.Add("@LastName", SqlDbType.NVarChar, 50).Value = lastName;
                command.Parameters.Add("@FirstName", SqlDbType.NVarChar, 50).Value = firstName;
                command.Parameters.Add("@MiddleName", SqlDbType.NVarChar, 50).Value =
                    (object)middleName ?? DBNull.Value;
                command.Parameters.Add("@Email", SqlDbType.NVarChar, 254).Value = email;
                command.Parameters.Add("@RoleID", SqlDbType.Int).Value = roleID;
                command.ExecuteNonQuery();
            }
        }

        public void SetUserActive(int actorUserID, int targetUserID, bool isActive)
        {
            // Kani nga procedure nag-toggle sa active status sa user account.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserSetActive, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@TargetUserID", SqlDbType.Int).Value = targetUserID;
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
                command.ExecuteNonQuery();
            }
        }

        public void AdminResetPassword(int actorUserID, int targetUserID, string newHash)
        {
            // Kani nga procedure nag-reset sa password ug gi-force ang pag-usab sa sunod login.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserAdminResetPassword, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@TargetUserID", SqlDbType.Int).Value = targetUserID;
                command.Parameters.Add("@NewHash", SqlDbType.VarChar, 255).Value = newHash;
                command.ExecuteNonQuery();
            }
        }

        public IList<RoleRecord> GetRoles(int actorUserID)
        {
            // Kani nga procedure nagkuha sa tanang roles ug ilang permission codes.
            var roles = new List<RoleRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.RolesGetAll, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        roles.Add(MapRoleRecord(reader));
                    }
                }
            }

            return roles;
        }

        public IList<PermissionRecord> GetPermissions(int actorUserID)
        {
            // Kani nga procedure nagkuha sa tanang permission definitions.
            var permissions = new List<PermissionRecord>();
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.PermissionsGetAll, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        permissions.Add(new PermissionRecord
                        {
                            PermissionID = Convert.ToInt32(reader["PermissionID"]),
                            PermissionCode = reader["PermissionCode"] as string,
                            Description = reader["Description"] as string
                        });
                    }
                }
            }

            return permissions;
        }

        public int CreateRole(
            int actorUserID,
            string roleName,
            string description,
            string permissionCodes)
        {
            // Kani nga procedure nag-himo og bag-ong role ug nagbalik sa bag-ong ID.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.RoleCreate, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@RoleName", SqlDbType.NVarChar, 50).Value = roleName;
                command.Parameters.Add("@Description", SqlDbType.NVarChar, 200).Value =
                    (object)description ?? DBNull.Value;
                command.Parameters.Add("@PermissionCodes", SqlDbType.NVarChar, -1).Value =
                    permissionCodes;

                var result = command.ExecuteScalar();
                return Convert.ToInt32(result);
            }
        }

        public void UpdateRole(
            int actorUserID,
            int roleID,
            string roleName,
            string description,
            bool isActive)
        {
            // Kani nga procedure nag-update sa role details ug status.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.RoleUpdate, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@RoleID", SqlDbType.Int).Value = roleID;
                command.Parameters.Add("@RoleName", SqlDbType.NVarChar, 50).Value = roleName;
                command.Parameters.Add("@Description", SqlDbType.NVarChar, 200).Value =
                    (object)description ?? DBNull.Value;
                command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
                command.ExecuteNonQuery();
            }
        }

        public void SetRolePermissions(
            int actorUserID,
            int roleID,
            string permissionCodes)
        {
            // Kani nga procedure nag-replace sa tanang permissions sa role.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.RoleSetPermissions, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@RoleID", SqlDbType.Int).Value = roleID;
                command.Parameters.Add("@PermissionCodes", SqlDbType.NVarChar, -1).Value =
                    permissionCodes;
                command.ExecuteNonQuery();
            }
        }

        public void CreateUser(
            int actorUserID,
            string lastName,
            string firstName,
            string middleName,
            string username,
            string passwordHash,
            string email,
            int roleID)
        {
            // Kani nga procedure nag-himo og bag-ong user account nga may audit log.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserCreate, connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@LastName", SqlDbType.NVarChar, 50).Value = lastName;
                command.Parameters.Add("@FirstName", SqlDbType.NVarChar, 50).Value = firstName;
                command.Parameters.Add("@MiddleName", SqlDbType.NVarChar, 50).Value =
                    (object)middleName ?? DBNull.Value;
                command.Parameters.Add("@Username", SqlDbType.NVarChar, 50).Value = username;
                command.Parameters.Add("@PasswordHash", SqlDbType.VarChar, 255).Value = passwordHash;
                command.Parameters.Add("@Email", SqlDbType.NVarChar, 254).Value = email;
                command.Parameters.Add("@RoleID", SqlDbType.Int).Value = roleID;
                command.ExecuteNonQuery();
            }
        }

        public void AssignRole(int actorUserID, int targetUserID, int newRoleID)
        {
            // Kani nga procedure nag-usab sa role sa user nga may audit log.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(StoredProcedureNames.UserAssignRole, connection)
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

        private static UserListItem MapUserListItem(IDataRecord row)
        {
            // Kani nga mapping kay nag-convert sa reader row ngadto sa model.
            return new UserListItem
            {
                UserID = Convert.ToInt32(row["UserID"]),
                LastName = row["LastName"] as string,
                FirstName = row["FirstName"] as string,
                MiddleName = row["MiddleName"] as string,
                Username = row["Username"] as string,
                Email = row["Email"] as string,
                RoleID = Convert.ToInt32(row["RoleID"]),
                RoleName = row["RoleName"] as string,
                IsActive = Convert.ToBoolean(row["IsActive"]),
                MustChangePassword = Convert.ToBoolean(row["MustChangePassword"]),
                FailedLoginAttempts = Convert.ToInt32(row["FailedLoginAttempts"]),
                LockoutEnd = row["LockoutEnd"] == DBNull.Value
                    ? (DateTime?)null
                    : Convert.ToDateTime(row["LockoutEnd"]),
                LastLogin = row["LastLogin"] == DBNull.Value
                    ? (DateTime?)null
                    : Convert.ToDateTime(row["LastLogin"]),
                DateCreated = Convert.ToDateTime(row["DateCreated"])
            };
        }

        private static RoleRecord MapRoleRecord(IDataRecord row)
        {
            // Kani nga mapping kay nag-parse sa CSV permission codes gikan sa procedure.
            var codes = row["PermissionCodes"] as string ?? string.Empty;
            var permissionCodes = new List<string>();
            foreach (var code in codes.Split(','))
            {
                var trimmed = code.Trim();
                if (trimmed.Length > 0)
                {
                    permissionCodes.Add(trimmed);
                }
            }

            return new RoleRecord
            {
                RoleID = Convert.ToInt32(row["RoleID"]),
                RoleName = row["RoleName"] as string,
                Description = row["Description"] == DBNull.Value
                    ? null
                    : row["Description"] as string,
                IsActive = Convert.ToBoolean(row["IsActive"]),
                ActiveUserCount = Convert.ToInt32(row["ActiveUserCount"]),
                PermissionCodes = permissionCodes
            };
        }
    }
}
