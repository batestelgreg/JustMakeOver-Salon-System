using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Utilities;
using Microsoft.Win32;

namespace JustMakeOverSalonApp.DataAccess
{
    /// <summary>
    /// Automatically ensures the salon SQL database exists and is initialized
    /// on first launch (using SQLEXPRESS if available, or LocalDB fallback),
    /// eliminating manual database setup steps after installation.
    /// </summary>
    internal static class DatabaseBootstrapper
    {
        private const string DefaultLocalDbSource = @"(LocalDB)\MSSQLLocalDB";
        private static readonly Regex GoBatchRegex = new Regex(
            @"^\s*GO\s*;?\s*$",
            RegexOptions.Multiline | RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SafeDbNameRegex = new Regex(
            @"^[A-Za-z0-9_]+$",
            RegexOptions.Compiled);

        public static bool EnsureDatabaseReady()
        {
            try
            {
                string configuredRaw = SqlConnectionFactory.ReadConfiguredConnectionString();
                var baseBuilder = new SqlConnectionStringBuilder(configuredRaw);
                string targetDatabase = string.IsNullOrWhiteSpace(baseBuilder.InitialCatalog)
                    ? "JustMakeOverSalonDB"
                    : baseBuilder.InitialCatalog.Trim();

                if (!SafeDbNameRegex.IsMatch(targetDatabase))
                {
                    throw new InvalidOperationException("Unsupported database name in configuration.");
                }

                List<string> candidates = BuildDataSourceCandidates(baseBuilder.DataSource);
                Exception lastError = null;

                foreach (string dataSource in candidates)
                {
                    if (TryInitializeOnServer(baseBuilder, dataSource, targetDatabase, out string resolvedConnStr, out Exception error))
                    {
                        SqlConnectionFactory.SetResolvedConnectionString(resolvedConnStr);
                        return true;
                    }

                    lastError = error;
                }

                string detail = lastError != null
                    ? lastError.Message
                    : "No SQL Server Express or LocalDB instance could be reached.";

                if (lastError != null)
                {
                    ErrorLog.Write("DatabaseBootstrapper", lastError);
                }

                MessageBox.Show(
                    "Unable to initialize the Just MakeOver Salon database.\n\n" +
                    detail + "\n\n" +
                    "Please ensure SQL Server LocalDB or SQL Server Express is installed and running.",
                    "Database Setup Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);

                return false;
            }
            catch (Exception ex)
            {
                ErrorLog.Write("DatabaseBootstrapper", ex);
                MessageBox.Show(
                    "Database initialization failed: " + ex.Message,
                    "Database Setup Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return false;
            }
        }

        private static List<string> BuildDataSourceCandidates(string configuredSource)
        {
            var candidates = new List<string>();
            string primary = (configuredSource ?? string.Empty).Trim();

            if (!string.IsNullOrEmpty(primary))
            {
                bool skipMissingLocalExpress =
                    IsLocalSqlExpressSource(primary) && !IsLocalInstanceRegistered("SQLEXPRESS");

                if (!skipMissingLocalExpress)
                {
                    candidates.Add(primary);
                }
            }

            if (!candidates.Exists(s => string.Equals(s, DefaultLocalDbSource, StringComparison.OrdinalIgnoreCase)))
            {
                candidates.Add(DefaultLocalDbSource);
            }

            if (!string.IsNullOrEmpty(primary) && !candidates.Contains(primary))
            {
                candidates.Add(primary);
            }

            return candidates;
        }

        private static bool IsLocalSqlExpressSource(string source)
        {
            return string.Equals(source, @".\SQLEXPRESS", StringComparison.OrdinalIgnoreCase)
                || string.Equals(source, @"(local)\SQLEXPRESS", StringComparison.OrdinalIgnoreCase)
                || string.Equals(source, @"localhost\SQLEXPRESS", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsLocalInstanceRegistered(string instanceName)
        {
            try
            {
                // Check Windows service key first (not WOW64-redirected for 32-bit processes).
                using (RegistryKey svcKey = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Services\MSSQL$" + instanceName))
                {
                    if (svcKey != null)
                    {
                        return true;
                    }
                }

                RegistryView[] views = Environment.Is64BitOperatingSystem
                    ? new[] { RegistryView.Registry64, RegistryView.Registry32 }
                    : new[] { RegistryView.Default };

                foreach (RegistryView view in views)
                {
                    using (RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                    using (RegistryKey key = baseKey.OpenSubKey(
                        @"SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"))
                    {
                        if (key != null && key.GetValue(instanceName) != null)
                        {
                            return true;
                        }
                    }
                }

                return false;
            }
            catch
            {
                return true;
            }
        }

        private static bool TryInitializeOnServer(
            SqlConnectionStringBuilder template,
            string dataSource,
            string targetDatabase,
            out string resolvedConnectionString,
            out Exception error)
        {
            resolvedConnectionString = null;
            error = null;

            bool isLocalDb = dataSource.IndexOf("(LocalDB)", StringComparison.OrdinalIgnoreCase) >= 0;
            if (isLocalDb)
            {
                EnsureLocalDbInstanceStarted();
            }

            var masterBuilder = new SqlConnectionStringBuilder(template.ConnectionString)
            {
                DataSource = dataSource,
                InitialCatalog = "master",
                ConnectTimeout = isLocalDb ? 10 : 3
            };

            try
            {
                bool databaseCreated = false;
                using (var masterConn = new SqlConnection(masterBuilder.ConnectionString))
                {
                    masterConn.Open();

                    using (var existsCmd = masterConn.CreateCommand())
                    {
                        existsCmd.CommandText = "SELECT DB_ID(@dbName);";
                        existsCmd.Parameters.Add("@dbName", SqlDbType.NVarChar, 128).Value = targetDatabase;
                        object existingId = existsCmd.ExecuteScalar();

                        if (existingId == null || existingId == DBNull.Value)
                        {
                            using (var createCmd = masterConn.CreateCommand())
                            {
                                createCmd.CommandTimeout = 30;
                                createCmd.CommandText = "CREATE DATABASE [" + targetDatabase + "];";
                                createCmd.ExecuteNonQuery();
                                databaseCreated = true;
                            }
                        }
                    }
                }

                var appBuilder = new SqlConnectionStringBuilder(template.ConnectionString)
                {
                    DataSource = dataSource,
                    InitialCatalog = targetDatabase,
                    ConnectTimeout = 5
                };

                using (var appConn = new SqlConnection(appBuilder.ConnectionString))
                {
                    appConn.Open();

                    bool schemaReady;
                    using (var checkCmd = appConn.CreateCommand())
                    {
                        checkCmd.CommandText = "SELECT CASE WHEN OBJECT_ID(N'dbo.USERS', N'U') IS NOT NULL THEN 1 ELSE 0 END;";
                        schemaReady = Convert.ToInt32(checkCmd.ExecuteScalar()) == 1;
                    }

                    if (!schemaReady)
                    {
                        string setupScriptPath = ResolveSetupScriptPath();
                        if (setupScriptPath == null)
                        {
                            throw new FileNotFoundException(
                                "Database setup script (Database\\FullSetup.sql) was not found.");
                        }

                        RunSetupWithProgressForm(appConn, setupScriptPath, targetDatabase, databaseCreated);
                    }
                }

                resolvedConnectionString = appBuilder.ConnectionString;
                return true;
            }
            catch (Exception ex)
            {
                error = ex;
                return false;
            }
        }

        private static void EnsureLocalDbInstanceStarted()
        {
            string localDbExe = FindSqlLocalDbExePath() ?? "sqllocaldb";
            RunLocalDbCli(localDbExe, "create MSSQLLocalDB", 8000);
            RunLocalDbCli(localDbExe, "start MSSQLLocalDB", 8000);
        }

        private static string FindSqlLocalDbExePath()
        {
            try
            {
                string[] programRootCandidates =
                {
                    Environment.GetEnvironmentVariable("ProgramW6432"),
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)
                };

                var foundPaths = new List<string>();
                foreach (string root in programRootCandidates)
                {
                    if (string.IsNullOrWhiteSpace(root))
                    {
                        continue;
                    }

                    string sqlRoot = Path.Combine(root, "Microsoft SQL Server");
                    if (!Directory.Exists(sqlRoot))
                    {
                        continue;
                    }

                    foreach (string dir in Directory.GetDirectories(sqlRoot))
                    {
                        string candidate = Path.Combine(dir, "Tools", "Binn", "SqlLocalDB.exe");
                        if (File.Exists(candidate))
                        {
                            foundPaths.Add(candidate);
                        }
                    }
                }

                if (foundPaths.Count > 0)
                {
                    foundPaths.Sort(StringComparer.OrdinalIgnoreCase);
                    return foundPaths[foundPaths.Count - 1];
                }
            }
            catch
            {
                // Fall back to PATH lookup when directory probe fails.
            }

            return null;
        }

        private static void RunLocalDbCli(string exePath, string arguments, int timeoutMs)
        {
            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = exePath,
                    Arguments = arguments,
                    CreateNoWindow = true,
                    UseShellExecute = false
                };
                using (Process proc = Process.Start(startInfo))
                {
                    proc?.WaitForExit(timeoutMs);
                }
            }
            catch
            {
                // Ignore if SqlLocalDB CLI is unavailable; SqlClient auto-starts LocalDB when registered.
            }
        }

        private static string ResolveSetupScriptPath()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string[] candidates =
            {
                Path.Combine(baseDir, "Database", "FullSetup.sql"),
                Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "Database", "FullSetup.sql")),
                Path.GetFullPath(Path.Combine(baseDir, "..", "..", "Database", "FullSetup.sql"))
            };

            foreach (string candidate in candidates)
            {
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return null;
        }

        private static void RunSetupWithProgressForm(
            SqlConnection connection,
            string setupScriptPath,
            string targetDatabase,
            bool newlyCreated)
        {
            using (var statusForm = CreateSetupStatusForm())
            {
                statusForm.Show();
                Application.DoEvents();

                try
                {
                    ExecuteFullSetupScript(connection, setupScriptPath, targetDatabase);
                }
                catch
                {
                    if (newlyCreated)
                    {
                        CleanupFailedDatabase(connection.DataSource, targetDatabase);
                    }
                    throw;
                }
                finally
                {
                    statusForm.Close();
                }
            }
        }

        private static Form CreateSetupStatusForm()
        {
            var form = new Form
            {
                Text = "Just MakeOver Salon System",
                FormBorderStyle = FormBorderStyle.FixedDialog,
                StartPosition = FormStartPosition.CenterScreen,
                ControlBox = false,
                ShowInTaskbar = false,
                Size = new Size(420, 125),
                BackColor = Color.White
            };

            var label = new Label
            {
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Segoe UI", 10f, FontStyle.Regular),
                ForeColor = Color.FromArgb(24, 38, 56),
                Text = "Configuring salon database for first-time use...\nPlease wait a few seconds."
            };

            form.Controls.Add(label);
            return form;
        }

        private static void ExecuteFullSetupScript(
            SqlConnection connection,
            string setupScriptPath,
            string targetDatabase)
        {
            string sqlText = File.ReadAllText(setupScriptPath, Encoding.UTF8);
            string[] batches = GoBatchRegex.Split(sqlText);

            foreach (string rawBatch in batches)
            {
                string batch = rawBatch.Trim();
                if (string.IsNullOrEmpty(batch) || ShouldSkipSetupBatch(batch, targetDatabase))
                {
                    continue;
                }

                using (var cmd = connection.CreateCommand())
                {
                    cmd.CommandTimeout = 60;
                    cmd.CommandText = batch;
                    cmd.ExecuteNonQuery();
                }
            }
        }

        private static bool ShouldSkipSetupBatch(string batch, string targetDatabase)
        {
            if (batch.IndexOf("CREATE DATABASE", StringComparison.OrdinalIgnoreCase) >= 0
                && batch.IndexOf("DB_ID(", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }

            if (Regex.IsMatch(
                batch,
                @"^(?:--[^\r\n]*\r?\n)*\s*USE\s+\[?" + Regex.Escape(targetDatabase) + @"\]?\s*;?\s*$",
                RegexOptions.IgnoreCase))
            {
                return true;
            }

            return false;
        }

        private static void CleanupFailedDatabase(string dataSource, string targetDatabase)
        {
            try
            {
                var masterBuilder = new SqlConnectionStringBuilder
                {
                    DataSource = dataSource,
                    InitialCatalog = "master",
                    IntegratedSecurity = true,
                    ConnectTimeout = 5
                };
                using (var masterConn = new SqlConnection(masterBuilder.ConnectionString))
                {
                    masterConn.Open();
                    using (var cmd = masterConn.CreateCommand())
                    {
                        cmd.CommandText =
                            "IF DB_ID(@db) IS NOT NULL BEGIN " +
                            "ALTER DATABASE [" + targetDatabase + "] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; " +
                            "DROP DATABASE [" + targetDatabase + "]; END;";
                        cmd.Parameters.Add("@db", SqlDbType.NVarChar, 128).Value = targetDatabase;
                        cmd.ExecuteNonQuery();
                    }
                }
            }
            catch
            {
                // Ignore cleanup failure; primary exception will still be surfaced.
            }
        }
    }
}
