using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using JustMakeOverSalonApp.Bridge;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Services;
using JustMakeOverSalonApp.Utilities;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace JustMakeOverSalonApp
{
    // Kani nga form kay ang desktop host sa web frontend gamit ang WebView2.
    public class MainForm : Form
    {
        private const string VirtualHostName = "salon.local";

        private readonly WebView2 webView;
        private FrontendBridge frontendBridge;

        public MainForm()
        {
            Text = "Just MakeOver Salon System";
            StartPosition = FormStartPosition.CenterScreen;
            WindowState = FormWindowState.Maximized;
            MinimumSize = new System.Drawing.Size(1200, 720);
            BackColor = System.Drawing.Color.FromArgb(16, 29, 45);

            webView = new WebView2
            {
                Dock = DockStyle.Fill
            };

            Controls.Add(webView);

            Load += MainForm_Load;
        }

        private async void MainForm_Load(object sender, EventArgs e)
        {
            try
            {
                var frontendPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Frontend");
                var htmlPath = Path.Combine(frontendPath, "index.html");

                // Kani nga listahan kay mga kritikal nga files para molarga ang app.
                var criticalFiles = new[]
                {
                    htmlPath,
                    Path.Combine(frontendPath, "assets", "css", "tokens.css"),
                    Path.Combine(frontendPath, "assets", "js", "core", "app.js"),
                    Path.Combine(frontendPath, "pages", "login", "login.html"),
                    Path.Combine(frontendPath, "images", "logo.png")
                };

                // Kani nga check kay nagdili sa pagdagan kung dili kompleto ang frontend.
                var missingFiles = criticalFiles
                    .Where(file => !File.Exists(file))
                    .ToList();

                if (missingFiles.Count > 0)
                {
                    ShowStartupError(
                        "The application frontend is incomplete or was not copied correctly.\n\n" +
                        "Please rebuild the solution in Visual Studio (Build → Rebuild Solution).\n\n" +
                        "Missing files:\n" + string.Join("\n", missingFiles),
                        "Frontend Files Error");
                    return;
                }

                // Kani nga user data folder kay fixed location para sa WebView2 profile.
                var userDataFolder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "JustMakeOverSalonApp",
                    "WebView2");

                var environment = await CoreWebView2Environment.CreateAsync(
                    null,
                    userDataFolder);

                await webView.EnsureCoreWebView2Async(environment);
                ConfigureWebViewSecurity(frontendPath);
                RegisterServices();

                webView.Source = new Uri("https://" + VirtualHostName + "/index.html");
            }
            catch (Exception ex)
            {
                // Kani nga error kay mahitabo kung walay WebView2 runtime sa computer.
                ErrorLog.Write("MainForm:Load", ex);
                ShowStartupError(
                    "The application could not start the web interface.\n\n" +
                    "Please make sure the Microsoft Edge WebView2 Runtime is installed.\n\n" +
                    "Technical details were written to the application log.",
                    "Initialization Error");
            }
        }

        private void ConfigureWebViewSecurity(string frontendPath)
        {
            var core = webView.CoreWebView2;

            // Kani mga settings kay para sa security ug dev experience sa app.
#if DEBUG
            // Kani nga setting kay para mo-gana ang F12 dev tools sa debug builds.
            core.Settings.AreDevToolsEnabled = true;
            core.Settings.AreBrowserAcceleratorKeysEnabled = true;
#else
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
#endif
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;

            // Kani nga mapping kay nag-restrict sa web access sa frontend folder ra.
            core.SetVirtualHostNameToFolderMapping(
                VirtualHostName,
                frontendPath,
                CoreWebView2HostResourceAccessKind.Allow);

            // Kani nga custom serving kay nagsiguro nga sakto ang MIME type sa
            // matag file aron molihok ang ES modules ug CSS sa WebView2.
            core.AddWebResourceRequestedFilter(
                "https://" + VirtualHostName + "/*",
                CoreWebView2WebResourceContext.All);

            core.WebResourceRequested += (sender, resourceArgs) =>
            {
                resourceArgs.Response = ServeLocalFrontendFile(core, frontendPath, resourceArgs.Request.Uri);
            };

            // Kani nga guard kay nagdili sa navigation sa gawas sa approved host.
            core.NavigationStarting += (sender, navigationArgs) =>
            {
                var allowedHosts = new[]
                {
                    VirtualHostName,
                    "about:blank"
                };

                var host = navigationArgs.Uri;
                var isAllowed = host.StartsWith("https://" + VirtualHostName, StringComparison.OrdinalIgnoreCase)
                    || host.Equals("about:blank", StringComparison.OrdinalIgnoreCase);

                if (!isAllowed)
                {
                    navigationArgs.Cancel = true;
                }
            };

            // Kani nga handler kay nag-log sa mga frontend resources nga napakyas.
            core.WebResourceResponseReceived += (sender, resourceArgs) =>
            {
                try
                {
                    var response = resourceArgs.Response;
                    if (response != null && (int)response.StatusCode >= 400)
                    {
                        ErrorLog.Write("MainForm:Resource",
                            new InvalidOperationException(
                                "Frontend resource failed with status " +
                                response.StatusCode + ": " + resourceArgs.Request.Uri));
                    }
                }
                catch
                {
                    // Kani nga catch kay para dili ma-apektahan ang app sa logging errors.
                }
            };

            core.ProcessFailed += (sender, processArgs) =>
            {
                // Kani nga handler kay nag-log kung mag-fail ang webview process.
                ErrorLog.Write("MainForm:ProcessFailed",
                    new InvalidOperationException(
                        "WebView2 process failed: " + processArgs.ProcessFailedKind));            };

            core.WebMessageReceived += (sender, messageArgs) =>
            {
                // Kani nga event kay ang tanging channel sa javascript-to-c# messages.
                frontendBridge.HandleWebMessageReceived(messageArgs);
            };
        }

        private void RegisterServices()
        {
            // Kani nga services kay para sa bridge operations nga allowed sa frontend.
            var connectionFactory = new SqlConnectionFactory();
            var authService = new AuthService(
                new UserRepository(connectionFactory),
                new AuditRepository(connectionFactory));
            var dashboardService = new DashboardService(new DashboardRepository(connectionFactory));

            frontendBridge = new FrontendBridge(
                () => webView.CoreWebView2,
                this,
                authService,
                dashboardService);
        }

        private static void ShowStartupError(string message, string title)
        {
            MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        // Kani nga method kay mo-serve sa local frontend files nga may sakto nga MIME type.
        private static CoreWebView2WebResourceResponse ServeLocalFrontendFile(
            CoreWebView2 core,
            string frontendPath,
            string requestUri)
        {
            try
            {
                var uri = new Uri(requestUri);
                var relativePath = uri.AbsolutePath.TrimStart('/');

                // Kani nga guard kay nagdili sa path traversal gikan sa frontend folder.
                var localPath = Path.GetFullPath(Path.Combine(frontendPath, relativePath));
                if (!localPath.StartsWith(
                        Path.GetFullPath(frontendPath),
                        StringComparison.OrdinalIgnoreCase) ||
                    !File.Exists(localPath))
                {
                    return core.Environment.CreateWebResourceResponse(
                        null, 404, "Not Found", "Content-Type: text/plain");
                }

                var headers = "Content-Type: " + GetMimeType(localPath) +
                              "\r\nCache-Control: no-cache";

                // Kani nga stream kay gi-pass sa WebView2 ug siya ra ang mo-dispose.
                var stream = new FileStream(localPath, FileMode.Open, FileAccess.Read, FileShare.Read);
                return core.Environment.CreateWebResourceResponse(
                    stream, 200, "OK", headers);
            }
            catch (Exception ex)
            {
                // Kani nga catch kay para ang serving error dili maka-crash sa app.
                ErrorLog.Write("MainForm:ServeFile", ex);
                return core.Environment.CreateWebResourceResponse(
                    null, 500, "Server Error", "Content-Type: text/plain");
            }
        }

        // Kani nga method kay nag-map sa file extension ngadto sa MIME type.
        private static string GetMimeType(string filePath)
        {
            var extension = Path.GetExtension(filePath).ToLowerInvariant();
            switch (extension)
            {
                case ".html": return "text/html";
                case ".css": return "text/css";
                case ".js": return "text/javascript";
                case ".json": return "application/json";
                case ".png": return "image/png";
                case ".jpg":
                case ".jpeg": return "image/jpeg";
                case ".gif": return "image/gif";
                case ".svg": return "image/svg+xml";
                case ".ico": return "image/x-icon";
                case ".woff": return "font/woff";
                case ".woff2": return "font/woff2";
                default: return "application/octet-stream";
            }
        }
    }
}
