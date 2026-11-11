using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Security;
using JustMakeOverSalonApp.Core.Services;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Delivery.Operations;
using JustMakeOverSalonApp.Inventory.Operations;
using JustMakeOverSalonApp.Purchasing.Operations;
using JustMakeOverSalonApp.Requisition.Operations;
using JustMakeOverSalonApp.Utilities;
using Microsoft.Web.WebView2.Core;

namespace JustMakeOverSalonApp.Bridge
{
    // Kani nga bridge kay ang dispatcher sa tanang frontend operations.
    // Ang kada module kay naa na sa iya-iyang project (IModuleOperations),
    // busa dili na mo-edit dinhi ang mga module developers.
    public sealed class FrontendBridge : IOperationContext
    {
        private readonly Func<CoreWebView2> webviewProvider;
        private readonly System.Windows.Forms.Control uiThreadOwner;
        private readonly JavaScriptSerializer serializer;
        private readonly AuthService authService;
        private readonly DashboardService dashboardService;
        private readonly OperationRegistry operations = new OperationRegistry();

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

            serializer = new JavaScriptSerializer { MaxJsonLength = 20 * 1024 * 1024 };

            // Kani nga registration kay para sa core operations (auth ug dashboard).
            RegisterCoreOperations();

            // Kani nga modules kay may iya-iyang projects — usay file each, walay conflict.
            new Bridge.Modules.UsersModule().RegisterOperations(operations, this);
            new RequisitionModule().RegisterOperations(operations, this);
            new InventoryModule().RegisterOperations(operations, this);
            new PurchasingModule().RegisterOperations(operations, this);
            new DeliveryModule().RegisterOperations(operations, this);
        }

        // Kani nga method kay nag-enroll sa core operations nga dili module.
        private void RegisterCoreOperations()
        {
            operations.Register(OperationNames.Ping, (payload, requestID) =>
            {
                SendResponse(requestID, true, new { serverTime = DateTime.Now }, null);
                return Task.CompletedTask;
            });

            operations.Register(OperationNames.Login,
                (payload, requestID) => HandleLoginAsync(payload, requestID));

            operations.Register(OperationNames.Logout, (payload, requestID) =>
            {
                // Kani nga operation kay nag-clear sa session sa memory sa desktop app.
                SessionContext.Instance.SignOut();
                SendResponse(requestID, true, null, null);
                return Task.CompletedTask;
            });

            operations.Register(OperationNames.LoadDashboard,
                (payload, requestID) => HandleLoadDashboardAsync(requestID));

            operations.Register(OperationNames.ChangePassword,
                (payload, requestID) => HandleChangePasswordAsync(payload, requestID));

            operations.Register(OperationNames.LogClientError, (payload, requestID) =>
            {
                // Kani nga operation kay para sa javascript errors nga gi-log sa file.
                ErrorLog.WriteMessage("Frontend:ClientError",
                    GetValueAsString(payload, "message") ?? "Unknown");
                SendResponse(requestID, true, null, null);
                return Task.CompletedTask;
            });
        }

        // Kani nga handler kay tawagon sa MainForm kung naay message gikan sa JavaScript.
        public void HandleWebMessageReceived(CoreWebView2WebMessageReceivedEventArgs args)
        {
            string rawMessage;
            try
            {
                rawMessage = args.WebMessageAsJson;
            }
            catch (InvalidOperationException invalidOperation)
            {
                // Kani nga catch kay para sa closed webview nga dili na mo-respond.
                ErrorLog.Write("Bridge:Receive", invalidOperation);
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
                if (!operations.TryGetHandler(operation, out var handler))
                {
                    // Kani nga case kay mo-deny sa tanang operations nga wala rehistro.
                    SendResponse(requestID, false, null, "This operation is not available.");
                    return;
                }

                var payload = GetPayload(request);
                await handler(payload, requestID);
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

        // Kani nga handlers kay para sa core auth ug dashboard operations.
        private async Task HandleLoginAsync(Dictionary<string, object> payload, string requestID)
        {
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

        private async Task HandleLoadDashboardAsync(string requestID)
        {
            var user = RequireUser();
            var summary = await dashboardService.LoadSummaryAsync(user);
            SendResponse(requestID, true, summary, null);
        }

        private async Task HandleChangePasswordAsync(Dictionary<string, object> payload, string requestID)
        {
            var user = RequireUser();
            var currentPassword = GetValueAsString(payload, "currentPassword");
            var newPassword = GetValueAsString(payload, "newPassword");
            await authService.ChangePasswordAsync(user, currentPassword, newPassword);
            SendResponse(requestID, true, null, null);
        }

        // Kani nga method nagkuha sa payload object gikan sa request.
        private static Dictionary<string, object> GetPayload(Dictionary<string, object> request)
        {
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

        // Kani mga implementation kay para sa IOperationContext nga gigamit sa modules.
        public CurrentUser RequireUser()
        {
            return SessionContext.Instance.RequireUser();
        }

        public void SendResponse(string requestID, bool success, object result, string error)
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

        public string GetValueAsString(Dictionary<string, object> source, string key)
        {
            if (source == null || !source.TryGetValue(key ?? string.Empty, out var value) || value == null)
            {
                return null;
            }

            return value as string ?? value.ToString();
        }

        public int GetValueAsInt(Dictionary<string, object> source, string key)
        {
            var raw = GetValueAsString(source, key);
            return int.TryParse(raw, out var parsed) ? parsed : 0;
        }

        public IList<string> GetValueAsStringList(Dictionary<string, object> source, string key)
        {
            var values = new List<string>();
            if (source != null
                && source.TryGetValue(key ?? string.Empty, out var raw)
                && raw is System.Collections.ArrayList list)
            {
                foreach (var item in list)
                {
                    if (item != null)
                    {
                        values.Add(item.ToString());
                    }
                }
            }

            return values;
        }

        private void PostToBrowser(string json)
        {
            // Kani nga post kay kinahanglan sa UI thread kay ang WebView2 dili thread-safe.
            // Kani nga check kay una pa sa pag-access sa CoreWebView2 property.
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
