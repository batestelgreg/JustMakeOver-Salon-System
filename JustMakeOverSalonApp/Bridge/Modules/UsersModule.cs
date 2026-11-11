using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Services;

namespace JustMakeOverSalonApp.Bridge.Modules
{
    // Kani nga module kay nagdala sa tanang Users & Roles bridge operations.
    // Naga-impliment IModuleOperations aron mahimong pattern sa uban pang modules.
    public sealed class UsersModule : IModuleOperations
    {
        // Kani mga names kay ang operation contract tali sa frontend ug backend.
        private const string UsersList = "UsersList";
        private const string UserCreate = "UserCreate";
        private const string UserUpdate = "UserUpdate";
        private const string UserSetActive = "UserSetActive";
        private const string UserResetPassword = "UserResetPassword";
        private const string UserAssignRole = "UserAssignRole";
        private const string RolesList = "RolesList";
        private const string RoleSave = "RoleSave";

        private IOperationContext context;
        private UserManagementService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga service kay gihimo dinhi para iya ra ang module scope.
            this.context = context;
            this.service = new UserManagementService(
                new UserManagementRepository(new SqlConnectionFactory()));

            // Kani nga legacy aliases kay gibilin para sa backward compatibility.
            registry.Register("users.load", HandleUsersListAsync);
            registry.Register(UsersList, HandleUsersListAsync);
            registry.Register("users.create", HandleUserCreateAsync);
            registry.Register(UserCreate, HandleUserCreateAsync);
            registry.Register("users.deactivate", HandleUserSetActiveAsync);
            registry.Register(UserSetActive, HandleUserSetActiveAsync);
            registry.Register("users.assignRole", HandleUserAssignRoleAsync);
            registry.Register(UserAssignRole, HandleUserAssignRoleAsync);
            registry.Register(UserUpdate, HandleUserUpdateAsync);
            registry.Register(UserResetPassword, HandleUserResetPasswordAsync);
            registry.Register(RolesList, HandleRolesListAsync);
            registry.Register(RoleSave, HandleRoleSaveAsync);
        }

        // Kani nga handler kay kuhaon ang tanang users para sa frontend.
        private async Task HandleUsersListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var users = await service.LoadUsersAsync(actor);
            context.SendResponse(requestID, true, new { users }, null);
        }

        // Kani nga handler kay mo-himo og bag-ong user account.
        private async Task HandleUserCreateAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.CreateUserAsync(
                actor,
                context.GetValueAsString(payload, "lastName"),
                context.GetValueAsString(payload, "firstName"),
                context.GetValueAsString(payload, "middleName"),
                context.GetValueAsString(payload, "username"),
                context.GetValueAsString(payload, "password"),
                context.GetValueAsString(payload, "email"),
                context.GetValueAsInt(payload, "roleID"));
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler kay mo-toggle sa active status sa user account.
        private async Task HandleUserSetActiveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.SetUserActiveAsync(
                actor,
                context.GetValueAsInt(payload, "targetUserID"),
                context.GetValueAsString(payload, "isActive") == "true");
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler kay mo-usab sa role sa user.
        private async Task HandleUserAssignRoleAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.AssignRoleAsync(
                actor,
                context.GetValueAsInt(payload, "targetUserID"),
                context.GetValueAsInt(payload, "newRoleID"));
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler kay mo-update sa basic details sa user.
        private async Task HandleUserUpdateAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.UpdateUserAsync(
                actor,
                context.GetValueAsInt(payload, "targetUserID"),
                context.GetValueAsString(payload, "lastName"),
                context.GetValueAsString(payload, "firstName"),
                context.GetValueAsString(payload, "middleName"),
                context.GetValueAsString(payload, "email"),
                context.GetValueAsInt(payload, "roleID"));
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler kay mo-reset sa password sa user pinaagi sa admin.
        private async Task HandleUserResetPasswordAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.ResetUserPasswordAsync(
                actor,
                context.GetValueAsInt(payload, "targetUserID"),
                context.GetValueAsString(payload, "newPassword"));
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler kay nagdala sa roles ug permissions para sa role editor.
        private async Task HandleRolesListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var roles = await service.LoadRolesAsync(actor);
            var permissions = await service.LoadPermissionsAsync(actor);
            context.SendResponse(requestID, true, new { roles, permissions }, null);
        }

        // Kani nga handler kay nag-save sa role: create kung walay roleID, update kung naa.
        private async Task HandleRoleSaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var roleIDValue = context.GetValueAsString(payload, "roleID");
            var permissionCodes = context.GetValueAsStringList(payload, "permissionCodes");

            if (string.IsNullOrEmpty(roleIDValue))
            {
                var newRoleID = await service.CreateRoleAsync(
                    actor,
                    context.GetValueAsString(payload, "roleName"),
                    context.GetValueAsString(payload, "description"),
                    permissionCodes);
                context.SendResponse(requestID, true, new { roleID = newRoleID }, null);
                return;
            }

            await service.UpdateRoleAsync(
                actor,
                System.Convert.ToInt32(roleIDValue),
                context.GetValueAsString(payload, "roleName"),
                context.GetValueAsString(payload, "description"),
                context.GetValueAsString(payload, "isActive") == "true");
            await service.SetRolePermissionsAsync(
                actor, System.Convert.ToInt32(roleIDValue), permissionCodes);
            context.SendResponse(requestID, true, null, null);
        }
    }
}
