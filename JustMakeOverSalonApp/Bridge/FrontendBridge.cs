using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Security;
using JustMakeOverSalonApp.Core.Services;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Utilities;
using Microsoft.Web.WebView2.Core;

namespace JustMakeOverSalonApp.Bridge
{
    // Kani nga bridge kay tanging daan sa frontend aron mo-call sa backend operations.
    public sealed class FrontendBridge
    {
        private readonly Func<CoreWebView2> webviewProvider;
        private readonly System.Windows.Forms.Control uiThreadOwner;
        private readonly JavaScriptSerializer serializer;
        private readonly AuthService authService;
        private readonly DashboardService dashboardService;
        private readonly UserRepository userRepository;

        public FrontendBridge(
            Func<CoreWebView2> webviewProvider,
            System.Windows.Forms.Control uiThreadOwner,
            AuthService authService,
            DashboardService dashboardService)
        {
            this.webviewProvider = webviewProvider ?? throw new ArgumentNullException(nameof(webviewProvider));
            this.uiThreadOwner = uiThreadOwner ?? throw new ArgumentNullException(nameof(uiThreadOwner));
            this.authService = authService ?? throw new ArgumentNullException(nameof(authService));
            this.dashboardService = dashboardService ?? throw new ArgumentNullException(nameof(dashboardService));

            // Gi-instantiate nato ang UserRepository diri aron dili ma-error ang MainForm constructor.
            this.userRepository = new UserRepository(new SqlConnectionFactory());

            serializer = new JavaScriptSerializer { MaxJsonLength = 20 * 1024 * 1024 };
        }

        // Kani nga handler kay tawagon sa MainForm kung naay message gikan sa JavaScript.
        public void HandleWebMessageReceived(CoreWebView2WebMessageReceivedEventArgs args)
        {
            if (args == null)
            {
                return;
            }

            string rawMessage;
            try
            {
                rawMessage = args.WebMessageAsJson;
            }
            catch (InvalidOperationException)
            {
                return;
            }

            // Kani nga call kay mo-process sa message sa background aron dili ma-freeze ang UI.
            Task.Run(() => ProcessMessageAsync(rawMessage));
        }

        // Kani nga method kay async aron masakpan tanang errors sulod sa try/catch.
        private async Task ProcessMessageAsync(string rawMessage)
        {
            Dictionary<string, object> request;
            try
            {
                request = serializer.Deserialize<Dictionary<string, object>>(rawMessage);
            }
            catch (ArgumentException)
            {
                SendResponse(null, false, null, "The application received an invalid request.");
                return;
            }

            if (request == null)
            {
                SendResponse(null, false, null, "The application received an invalid request.");
                return;
            }

            var requestID = GetValueAsString(request, "requestId");
            var operation = GetValueAsString(request, "operation");

            // Kani nga trace kay para makita ang eksaktong pagkasunod-sunod sa operations.
            ErrorLog.WriteMessage(
                "Bridge:Trace",
                "Operation received: " + operation +
                " (session=" + (SessionContext.Instance.CurrentUser != null
                    ? SessionContext.Instance.CurrentUser.Username
                    : "none") + ")");

            try
            {
                var payload = GetPayload(request);
                await ExecuteOperationAsync(operation, payload, requestID);
            }
            catch (BusinessException businessError)
            {
                // Kani nga log kay para mahibaw-an kung asa nga operation ang napakyas.
                ErrorLog.WriteMessage("Bridge:" + operation + ":BusinessRule", businessError.Message);
                SendResponse(requestID, false, null, businessError.Message);
            }
            catch (SqlException sqlError)
            {
                // Kani nga error kay i-log ra ang details ug mo-hatag og safe message sa user.
                ErrorLog.Write("Bridge:" + operation, sqlError);
                SendResponse(requestID, false, null,
                    "The application could not reach the database. Please try again or contact the administrator.");
            }
            catch (Exception unexpected)
            {
                ErrorLog.Write("Bridge:" + operation, unexpected);
                SendResponse(requestID, false, null,
                    "An unexpected error occurred. Please try again or contact the administrator.");
            }
        }

        // Kani nga method kay async Task aron ang mga await errors ma-catch sa caller.
        private async Task ExecuteOperationAsync(string operation, Dictionary<string, object> payload, string requestID)
        {
            switch (operation)
            {
                case OperationNames.Ping:
                    SendResponse(requestID, true, new { serverTime = DateTime.Now }, null);
                    return;

                case OperationNames.Login:
                    await HandleLoginAsync(payload, requestID);
                    return;

                case OperationNames.Logout:
                    HandleLogout(requestID);
                    return;

                case OperationNames.LoadDashboard:
                    await HandleLoadDashboardAsync(requestID);
                    return;

                case OperationNames.ChangePassword:
                    await HandleChangePasswordAsync(payload, requestID);
                    return;

                // Kani nga mga operations para sa Users and Roles module
                case "users.load":
                case "LoadUsers":
                    await HandleLoadUsersAsync(requestID);
                    return;

                case "users.create":
                case "CreateUser":
                    await HandleCreateUserAsync(payload, requestID);
                    return;

                case "users.deactivate":
                case "DeactivateUser":
                    await HandleDeactivateUserAsync(payload, requestID);
                    return;

                case "users.assignRole":
                case "AssignRole":
                    await HandleAssignRoleAsync(payload, requestID);
                    return;

                case OperationNames.LogClientError:
                    // Kani nga operation kay para sa javascript errors nga gi-log sa file.
                    ErrorLog.Write("Frontend:" + (GetValueAsString(payload, "message") ?? "Unknown"),
                        new InvalidOperationException("Frontend error reported."));
                    SendResponse(requestID, true, null, null);
                    return;

                default:
                    // Kani nga case kay mo-deny sa tanang operations nga wala rehistro.
                    SendResponse(requestID, false, null, "This operation is not available.");
                    return;
            }
        }

        private async Task HandleLoginAsync(Dictionary<string, object> payload, string requestID)
        {
            // Kani nga operation kay mo-authenticate sa user gamit ang database procedures.
            var username = GetValueAsString(payload, "username");
            var password = GetValueAsString(payload, "password");
            var ipAddress = "127.0.0.1";

            var result = await authService.LoginAsync(username, password, ipAddress);
            if (!result.Success)
            {
                SendResponse(requestID, false, null, result.SafeMessage);
                return;
            }

            SessionContext.Instance.SignIn(result.User);

            // Kani nga log kay para makumpirma nga naa na ang session sa backend.
            ErrorLog.WriteMessage("Bridge:Login:Session",
                "Session signed in for user " + result.User.UserID +
                " (" + result.User.RoleName + ").");

            SendResponse(requestID, true, new
            {
                user = new
                {
                    userID = result.User.UserID,
                    fullName = result.User.FullName,
                    role = result.User.RoleName,
                    mustChangePassword = result.User.MustChangePassword
                },
                permissions = new List<string>(result.User.Permissions)
            }, null);
        }

        private void HandleLogout(string requestID)
        {
            // Kani nga operation kay nag-clear sa session sa memory sa desktop app.
            SessionContext.Instance.SignOut();
            SendResponse(requestID, true, null, null);
        }

        private async Task HandleLoadDashboardAsync(string requestID)
        {
            // Kani nga log kay para sa debugging sa session state sa dashboard.
            var user = SessionContext.Instance.RequireUser();
            ErrorLog.WriteMessage("Bridge:LoadDashboard:Session",
                "Dashboard loading for user " + user.UserID + ".");
            var summary = await dashboardService.LoadSummaryAsync(user);
            SendResponse(requestID, true, summary, null);
        }

        private async Task HandleChangePasswordAsync(Dictionary<string, object> payload, string requestID)
        {
            // Kani nga operation kay mo-verify sa current password ug mo-update sa bag-ong password.
            var user = SessionContext.Instance.RequireUser();
            var currentPassword = GetValueAsString(payload, "currentPassword");
            var newPassword = GetValueAsString(payload, "newPassword");
            await authService.ChangePasswordAsync(user, currentPassword, newPassword);
            SendResponse(requestID, true, null, null);
        }

        // Kani nga method kay kuhaon ang tanang users para sa frontend
        private async Task HandleLoadUsersAsync(string requestID)
        {
            var user = SessionContext.Instance.RequireUser();
            var users = await Task.Run(() => userRepository.GetAllUsers());
            SendResponse(requestID, true, users, null);
        }

        // Kani nga method kay mo-handle sa paghimo og bag-ong user account
        private async Task HandleCreateUserAsync(Dictionary<string, object> payload, string requestID)
        {
            var currentUser = SessionContext.Instance.RequireUser();
            var lastName = GetValueAsString(payload, "lastName");
            var firstName = GetValueAsString(payload, "firstName");
            var middleName = GetValueAsString(payload, "middleName");
            var username = GetValueAsString(payload, "username");
            var rawPassword = GetValueAsString(payload, "password");
            var email = GetValueAsString(payload, "email");
            var roleID = Convert.ToInt32(GetValueAsString(payload, "roleID") ?? "0");

            var passwordHash = PasswordHasher.HashPassword(rawPassword);

            await Task.Run(() => userRepository.CreateUser(currentUser.UserID, lastName, firstName, middleName, username, passwordHash, email, roleID));
            SendResponse(requestID, true, null, null);
        }

        // Kani nga method kay mo-handle sa pag-deactivate sa user account
        private async Task HandleDeactivateUserAsync(Dictionary<string, object> payload, string requestID)
        {
            var currentUser = SessionContext.Instance.RequireUser();
            var targetUserID = Convert.ToInt32(GetValueAsString(payload, "targetUserID") ?? "0");
            var reason = GetValueAsString(payload, "reason");

            await Task.Run(() => userRepository.DeactivateUser(currentUser.UserID, targetUserID, reason));
            SendResponse(requestID, true, null, null);
        }

        // Kani nga method kay mo-handle sa pag-assign og role sa user
        private async Task HandleAssignRoleAsync(Dictionary<string, object> payload, string requestID)
        {
            var currentUser = SessionContext.Instance.RequireUser();
            var targetUserID = Convert.ToInt32(GetValueAsString(payload, "targetUserID") ?? "0");
            var newRoleID = Convert.ToInt32(GetValueAsString(payload, "newRoleID") ?? "0");

            await Task.Run(() => userRepository.AssignRole(currentUser.UserID, targetUserID, newRoleID));
            SendResponse(requestID, true, null, null);
        }

        private static Dictionary<string, object> GetPayload(Dictionary<string, object> request)
        {
            // Kani nga method kay nagkuha sa payload object gikan sa request.
            if (!request.TryGetValue("payload", out var payload))
            {
                return new Dictionary<string, object>();
            }

            var payloadDictionary = payload as Dictionary<string, object>;
            if (payloadDictionary == null && payload != null)
            {
                throw new BusinessException("The request payload is not valid.");
            }

            return payloadDictionary ?? new Dictionary<string, object>();
        }

        private static string GetValueAsString(Dictionary<string, object> source, string key)
        {
            if (source == null || !source.TryGetValue(key, out var value) || value == null)
            {
                return null;
            }

            return value as string ?? value.ToString();
        }

        private void SendResponse(string requestID, bool success, object result, string error)
        {
            // Kani nga response kay structured contract nga gigamit sa frontend bridge module.
            var response = new Dictionary<string, object>
            {
                ["requestId"] = requestID,
                ["success"] = success,
                ["result"] = result,
                ["error"] = error
            };

            var json = serializer.Serialize(response);
            PostToBrowser(json);
        }

        private void PostToBrowser(string json)
        {
            // Kani nga post kay kinahanglan sa UI thread kay ang WebView2 dili thread-safe.
            if (uiThreadOwner != null && uiThreadOwner.InvokeRequired)
            {
                uiThreadOwner.BeginInvoke(new Action(() =>
                {
                    var webview = webviewProvider();
                    if (webview != null)
                    {
                        PostSafely(webview, json);
                    }
                }));
                return;
            }

            var core = webviewProvider();
            if (core == null)
            {
                return;
            }

            PostSafely(core, json);
        }

        private static void PostSafely(CoreWebView2 webview, string json)
        {
            try
            {
                webview.PostWebMessageAsJson(json);
            }
            catch (InvalidOperationException invalidOperation)
            {
                // Kani nga catch kay mo-hold kung sirado na ang webview samtang nag-post.
                ErrorLog.Write("Bridge:PostResponse", invalidOperation);
            }
        }
    }
}