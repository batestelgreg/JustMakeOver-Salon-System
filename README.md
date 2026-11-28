# Just MakeOver Salon System

An integrated desktop operations, inventory, procurement, and internal delivery management system built for **Just MakeOver Beauty Salon & Spa**.

Designed with maker-checker security controls, automated stock allocation & replenishment workflows, digital signatures with SHA-256 verification, Official Salon Email (SMTP) purchase order dispatch, and a single-click Windows installer with automatic SQL database provisioning.

---

## Tech Stack & Architecture

- **Desktop Host:** C#, `.NET Framework 4.8` (Windows Forms)
- **User Interface:** Microsoft Edge `WebView2` hosting modular `HTML5`, `CSS3`, and `ES6 JavaScript` over a structured `FrontendBridge`
- **Database:** Microsoft SQL Server / SQL Server Express LocalDB (`39` tables, `113` stored procedures, `11` triggers, `3` scalar functions, `1` view, `1` sequence)
- **Modular Solution (`JustMakeOverSalonApp.slnx`):**
  - `JustMakeOverSalonApp` — WinForms WebView2 shell, `DatabaseBootstrapper`, Users & Roles bridge
  - `JustMakeOverSalonApp.Core` — Authentication (`PBKDF2-SHA256`), RBAC, session context, encryption (`DPAPI`), digital signatures, connection factory
  - Domain Modules: `Requisition`, `Inventory`, `Purchasing`, `Receiving`, `Delivery`, `Suppliers`, `Notifications`, `Reports`, `Settings`

---

## Implemented Modules

- **Authentication & Security:** PBKDF2-SHA256 password hashing (`100,000` iterations), 5-attempt / 15-minute account lockout, forced password change on first login, self-service password change, Admin password resets, Role-Based Access Control (`27` permissions across `5` customizable roles), and full audit logging.
- **Dashboard:** Role-filtered live operational summary cards, inventory overview, quick actions, and database health status.
- **Requisitions:** Online Requisition Form (`RF`), required-field validation, Department Head approval/rejection with digital signature, pending cancellation, revise-and-resubmit flow, and printable RF documents.
- **Inventory:** Live `On Hand`, `Reserved`, and persisted `Available` stock tracking, automatic reservation & replenishment (`RepF`) generation on shortages, reorder-point low-stock alerts, manual stock adjustments, movement logs, and printable Stock Cards & RepF requests.
- **Purchasing & Suppliers:** Supplier master list, Purchase Requests (`PR`) with e-signature, 1–3 supplier quotations & automated lowest-price comparison, annual budget checks, Purchase Order (`PO`) approval with e-signature, direct Official Salon Email (`SMTP` via MailKit) dispatch & delivery logs, Supplier Delivery Checks (`DR`), printable Return Slips, Replacement Email Drafts, and automated overdue follow-up reminders.
- **Receiving:** Checked-DR queue from Purchasing (`e-sign` locked Receiving Memos), manual receive without reference, automatic allocation to waiting approved requisitions, and printable Receiving Reports (`RR`).
- **Delivery:** Acknowledgement Receipt (`AR`) generation, item issuance (`e-sign`), requestor discrepancy reporting, Inventory correction logging (`e-sign`) & AR re-issue loop, requestor digital acknowledgement, automatic stock deduction, requisition fulfillment/archiving, and printable AR & Correction Reports.
- **Notifications, Reports & Settings:** Notification bell popover and full history with direct navigation & row highlighting; centralized read-only Reports catalog with `CSV`, `Excel`, and Print/PDF exports; Categories, Units of Measure, Branding Preferences, and DPAPI-encrypted Official Salon Email configuration.

---

## Single-Click Installation Guide (End Users)

> **Requirements:** Windows 10 or Windows 11 (64-bit) with `.NET Framework 4.8`. No manual SQL Server Management Studio (SSMS) setup is required.

1. Go to the **[GitHub Releases](https://github.com/batestelgreg/JustMakeOverSalonSystem-App/releases)** page of this repository.
2. Under the latest release **Assets**, download **`JustMakeOverSalonSetup.exe`**.
3. Double-click **`JustMakeOverSalonSetup.exe`** (click *Yes* if prompted by Windows User Account Control).
4. Follow the setup wizard (**Next -> Install -> Finish**):
   - If neither SQL Server Express nor SQL Server LocalDB is detected on the PC, the installer automatically installs **SQL Server Express LocalDB** silently.
   - If Microsoft Edge WebView2 Runtime is missing, the installer installs it automatically.
5. Launch **Just MakeOver Salon System** from the Desktop or Start Menu shortcut.
6. On the **first launch**, wait a few seconds while the application automatically creates `JustMakeOverSalonDB` and initializes all tables, stored procedures, triggers, and starter roles/settings using `Database\FullSetup.sql`.

---

## Default Starter Admin Account

Use the following temporary credentials after a fresh clean-starter installation:

| Field | Value |
|---|---|
| **Username** | `admin` |
| **Temporary Password** | `Admin@1234` |
| **Role** | `Admin` |

### First-Login Setup Steps
1. Sign in with `admin` and `Admin@1234`.
2. When prompted by the **Set a new password** screen, create your permanent strong password (*minimum 8 characters, with at least 1 uppercase letter, 1 lowercase letter, 1 number, and 1 special character*).
3. Open **Users & Roles** to create accounts for **Manager**, **Inventory Staff**, **Purchasing Staff**, and **Staff** users *(each new user receives a temporary password and is required to change it on first login)*.
4. *(Optional)* Open **Settings -> Official Salon Email (SMTP)** to configure the centralized salon Gmail + 16-character App Password for sending Purchase Orders, Follow-Ups, and Replacement emails.

---

## Developer Setup (Build from Source)

1. Clone the repository:
   ```powershell
   git clone https://github.com/batestelgreg/JustMakeOverSalonSystem-App.git
   ```
2. Open **`JustMakeOverSalonApp.slnx`** in **Visual Studio**.
3. Restore NuGet packages (`Microsoft.Web.WebView2`, `MailKit`, `MimeKit`, etc.).
4. Database configuration:
   - By default, `JustMakeOverSalonApp\App.config` targets `.\SQLEXPRESS` (`Initial Catalog=JustMakeOverSalonDB`) and automatically falls back to `(LocalDB)\MSSQLLocalDB` if `SQLEXPRESS` is not installed.
   - Consolidated clean-starter database script: `Database\FullSetup.sql`
   - Incremental schema history scripts: `Database\Migrations\` (`V000`–`V042`)
5. Build and run (`F5`) in **Debug** or **Release**.

### Building the Single-Click Installer
1. Install **Inno Setup** (`ISCC.exe`).
2. Run from PowerShell at the repository root:
   ```powershell
   .\Installer\BuildInstaller.ps1 -DownloadPrereqs
   ```
3. The compiled installer is generated at `Installer\Output\JustMakeOverSalonSetup.exe`.
