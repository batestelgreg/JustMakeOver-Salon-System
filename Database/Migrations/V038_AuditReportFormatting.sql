USE JustMakeOverSalonDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO


CREATE OR ALTER PROCEDURE dbo.usp_Report_LogAction
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @ActionType VARCHAR(30),
    @FilterSummary NVARCHAR(1000) = NULL,
    @RowCount INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActorRole NVARCHAR(100);

    SELECT @ActorRole = r.RoleName
    FROM dbo.USERS u
    INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF @ActorRole IS NULL
        RETURN;

    INSERT INTO dbo.REPORT_AUDIT_LOGS
    (
        ActorUserID, ActorRole, ReportCode, ActionType,
        FilterSummary, [RowCount], CreatedAt
    )
    VALUES
    (
        @ActorUserID, @ActorRole, LEFT(@ReportCode, 60),
        LEFT(@ActionType, 30), LEFT(@FilterSummary, 1000),
        @RowCount, SYSDATETIME()
    );

    IF @ActionType IN ('PRINT', 'EXPORT_CSV', 'EXPORT_EXCEL', 'DOC_PRINT')
    BEGIN
        DECLARE @CleanFilter NVARCHAR(250) = NULLIF(LTRIM(RTRIM(@FilterSummary)), N'');
        DECLARE @RowText NVARCHAR(40) =
            CASE
                WHEN @RowCount IS NULL THEN N''
                WHEN @RowCount = 1 THEN N'1 row'
                ELSE CONCAT(@RowCount, N' rows')
            END;

        DECLARE @Description NVARCHAR(500);

        IF @ActionType = 'DOC_PRINT'
        BEGIN
            SET @Description = CONCAT(
                N'Printed ',
                @ReportCode,
                N'.'
            );
        END
        ELSE
        BEGIN
            DECLARE @Verb NVARCHAR(40) =
                CASE @ActionType
                    WHEN 'PRINT' THEN N'Printed'
                    WHEN 'EXPORT_CSV' THEN N'Exported to CSV:'
                    WHEN 'EXPORT_EXCEL' THEN N'Exported to Excel:'
                    ELSE @ActionType
                END;

            SET @Description = CONCAT(
                @Verb, N' ', @ReportCode,
                CASE
                    WHEN @RowText <> N'' AND @CleanFilter IS NOT NULL AND @CleanFilter <> N'All records'
                        THEN CONCAT(N' (', @RowText, N' · ', @CleanFilter, N')')
                    WHEN @RowText <> N''
                        THEN CONCAT(N' (', @RowText, N')')
                    WHEN @CleanFilter IS NOT NULL AND @CleanFilter <> N'All records'
                        THEN CONCAT(N' (', @CleanFilter, N')')
                    ELSE N''
                END,
                N'.'
            );
        END;

        INSERT INTO dbo.USER_AUDIT_LOGS
        (
            ActorUserID, TargetUserID, ActionType, Description
        )
        VALUES
        (
            @ActorUserID,
            @ActorUserID,
            'REPORT_' + LEFT(@ActionType, 20),
            LEFT(@Description, 500)
        );
    END;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Report_Audit
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID
          AND u.IsActive = 1
          AND p.PermissionCode = 'reports.audit'
    )
        THROW 50808, 'You do not have permission to view audit and security reports.', 1;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; UserID=', ISNULL(CAST(@RequestorUserID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode = 'AUD_PRINT_SIGNATURE'
    BEGIN
        DECLARE @SigAudit TABLE
        (
            EventDate DATETIME2(0),
            Category VARCHAR(30),
            DocumentType NVARCHAR(80),
            DocumentRef VARCHAR(40),
            StageOrAction VARCHAR(40),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            HashPrefix VARCHAR(20),
            IntegrityStatus VARCHAR(30),
            Details NVARCHAR(500)
        );

        INSERT INTO @SigAudit
        SELECT
            ds.SignedAt,
            'Digital Signature',
            CASE ds.DocumentType
                WHEN 'PURCHASE_ORDER' THEN N'Purchase Order'
                WHEN 'RECEIVING_REPORT' THEN N'Receiving Report'
                WHEN 'STOCK_CARD' THEN N'Stock Card'
                WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                WHEN 'REQUISITION' THEN N'Requisition Form'
                WHEN 'REPLENISHMENT_REQUEST' THEN N'Replenishment Request'
                WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                WHEN 'DELIVERY_CHECK' THEN N'Delivery Check'
                WHEN 'RETURN_SLIP' THEN N'Return Slip'
                ELSE ds.DocumentType
            END,
            CONCAT('#', ds.DocumentID),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            LEFT(ds.DocumentHash, 12),
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Snapshot Changed'
            END,
            CASE
                WHEN ds.IsActive = 0 THEN ISNULL(ds.RevokeReason, N'Revoked')
                ELSE N'Confirmed digital signature'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        WHERE (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.SignerUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ds.DocumentType = @Status)
        UNION ALL
        SELECT
            ral.CreatedAt,
            'Report / Print',
            ral.ReportCode,
            CONCAT('LOG-', ral.ReportAuditID),
            CASE ral.ActionType
                WHEN 'GENERATE' THEN 'Viewed'
                WHEN 'PRINT' THEN 'Printed'
                WHEN 'DOC_PRINT' THEN 'Printed Document'
                WHEN 'EXPORT_CSV' THEN 'Exported (CSV)'
                WHEN 'EXPORT_EXCEL' THEN 'Exported (Excel)'
                ELSE ral.ActionType
            END,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            ral.ActorRole,
            N'—',
            'Logged',
            ISNULL(ral.FilterSummary, N'')
        FROM dbo.REPORT_AUDIT_LOGS ral
        INNER JOIN dbo.USERS u ON u.UserID = ral.ActorUserID
        WHERE (@DateFrom IS NULL OR ral.CreatedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ral.CreatedAt <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ral.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR ral.ActionType = @Status);

        SELECT @RowCount = COUNT(*) FROM @SigAudit;

        SELECT
            @RowCount AS TotalEvents,
            ISNULL(SUM(CASE WHEN Category = 'Digital Signature' THEN 1 ELSE 0 END), 0) AS SignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedSignatures,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked' THEN 1 ELSE 0 END), 0) AS RevokedSignatures,
            ISNULL(SUM(CASE WHEN Category = 'Report / Print' THEN 1 ELSE 0 END), 0) AS ReportPrintEvents
        FROM @SigAudit;

        SELECT * FROM @SigAudit ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_CORRECTION_HISTORY'
    BEGIN
        DECLARE @CorHist TABLE
        (
            EventDate DATETIME2(0),
            RecordType VARCHAR(40),
            DocumentRef NVARCHAR(120),
            ActorName NVARCHAR(200),
            Summary NVARCHAR(1000),
            Status VARCHAR(30)
        );

        INSERT INTO @CorHist
        SELECT
            ISNULL(d.CorrectedAt, d.GeneratedDate),
            'AR Discrepancy / Correction',
            d.ARCode,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName)))
                 ELSE LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))) END,
            CONCAT(
                'Discrepancy: ', ISNULL(d.DiscrepancyNotes, N'—'),
                CASE WHEN d.CorrectionNotes IS NOT NULL THEN CONCAT(' | Correction: ', d.CorrectionNotes) ELSE '' END
            ),
            CASE WHEN d.DiscrepancyResolvedAt IS NOT NULL THEN 'Resolved' WHEN d.CorrectedAt IS NOT NULL THEN 'Corrected' ELSE 'Open' END
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        WHERE (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          AND (@DateFrom IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(d.CorrectedAt, d.GeneratedDate) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR d.CorrectedByUserID = @RequestorUserID OR d.RequestorUserID = @RequestorUserID)
        UNION ALL
        SELECT
            ISNULL(ds.RevokedAt, ds.SignedAt),
            'Signature Revoked / Superseded',
            CONCAT(
                CASE ds.DocumentType
                    WHEN 'PURCHASE_ORDER' THEN N'Purchase Order'
                    WHEN 'RECEIVING_REPORT' THEN N'Receiving Report'
                    WHEN 'STOCK_CARD' THEN N'Stock Card'
                    WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                    WHEN 'REQUISITION' THEN N'Requisition Form'
                    WHEN 'REPLENISHMENT_REQUEST' THEN N'Replenishment Request'
                    WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                    WHEN 'DELIVERY_CHECK' THEN N'Delivery Check'
                    WHEN 'RETURN_SLIP' THEN N'Return Slip'
                    ELSE ds.DocumentType
                END,
                N' #', ds.DocumentID, N' (', ds.Stage, N')'
            ),
            LTRIM(RTRIM(CONCAT(rv.FirstName, ' ', rv.LastName))),
            ISNULL(ds.RevokeReason, N'Revoked'),
            'Revoked'
        FROM dbo.DOCUMENT_SIGNATURES ds
        LEFT JOIN dbo.USERS rv ON rv.UserID = ds.RevokedByUserID
        WHERE ds.IsActive = 0
          AND (@DateFrom IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ISNULL(ds.RevokedAt, ds.SignedAt) <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR ds.RevokedByUserID = @RequestorUserID);

        SELECT @RowCount = COUNT(*) FROM @CorHist;

        SELECT
            @RowCount AS TotalCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'AR Discrepancy / Correction' THEN 1 ELSE 0 END), 0) AS DeliveryCorrections,
            ISNULL(SUM(CASE WHEN RecordType = 'Signature Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS SignatureRevocations
        FROM @CorHist;

        SELECT * FROM @CorHist ORDER BY EventDate DESC;
    END
    ELSE IF @ReportCode = 'AUD_USER_ACTIVITY'
    BEGIN
        DECLARE @Activity TABLE
        (
            AuditID BIGINT,
            ActionDate DATETIME2(0),
            ActorName NVARCHAR(200),
            ActorRole NVARCHAR(100),
            ActionType VARCHAR(60),
            TargetUser NVARCHAR(200),
            Description NVARCHAR(1000)
        );

        INSERT INTO @Activity
        SELECT TOP (1000)
            a.AuditID,
            a.ActionDate,
            LTRIM(RTRIM(CONCAT(actor.FirstName, ' ', actor.LastName))),
            r.RoleName,
            a.ActionType,
            CASE WHEN target.UserID IS NOT NULL
                 THEN LTRIM(RTRIM(CONCAT(target.FirstName, ' ', target.LastName)))
                 ELSE N'—' END,
            a.Description
        FROM dbo.USER_AUDIT_LOGS a
        INNER JOIN dbo.USERS actor ON actor.UserID = a.ActorUserID
        INNER JOIN dbo.ROLES r ON r.RoleID = actor.RoleID
        LEFT JOIN dbo.USERS target ON target.UserID = a.TargetUserID
        WHERE (@DateFrom IS NULL OR a.ActionDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR a.ActionDate <= @DateToEnd)
          AND (@RequestorUserID IS NULL OR a.ActorUserID = @RequestorUserID)
          AND (NULLIF(@Status, '') IS NULL OR a.ActionType = @Status)
        ORDER BY a.ActionDate DESC, a.AuditID DESC;

        SELECT @RowCount = COUNT(*) FROM @Activity;

        SELECT
            @RowCount AS TotalActivities,
            COUNT(DISTINCT ActorName) AS DistinctActors,
            COUNT(DISTINCT ActionType) AS DistinctActionTypes
        FROM @Activity;

        SELECT * FROM @Activity ORDER BY ActionDate DESC, AuditID DESC;
    END
    ELSE
        THROW 50809, 'Unknown audit report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO

/* 
   3. DELIVERY SIGNATURE HISTORY — Human-Readable Source Labels
*/

CREATE OR ALTER PROCEDURE dbo.usp_Report_Delivery
    @ActorUserID INT,
    @ReportCode VARCHAR(60),
    @DateFrom DATE = NULL,
    @DateTo DATE = NULL,
    @ItemID INT = NULL,
    @CategoryID INT = NULL,
    @Status VARCHAR(40) = NULL,
    @RequestorUserID INT = NULL,
    @DepartmentRole NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleName NVARCHAR(100);
    SELECT @RoleName = r.RoleName
    FROM dbo.USERS u INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
    WHERE u.UserID = @ActorUserID AND u.IsActive = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.USERS u
        INNER JOIN dbo.ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
        INNER JOIN dbo.PERMISSIONS p ON p.PermissionID = rp.PermissionID
        WHERE u.UserID = @ActorUserID AND p.PermissionCode = 'reports.view'
    )
        THROW 50806, 'You do not have permission to view delivery reports.', 1;

    DECLARE @ScopedRequestorID INT =
        CASE WHEN @RoleName = N'Staff' THEN @ActorUserID ELSE @RequestorUserID END;

    DECLARE @DateToEnd DATETIME2(0) =
        CASE WHEN @DateTo IS NOT NULL THEN DATEADD(SECOND, 86399, CAST(@DateTo AS DATETIME2(0))) ELSE NULL END;

    DECLARE @FilterDesc NVARCHAR(1000) = CONCAT(
        'DateFrom=', ISNULL(CONVERT(VARCHAR(10), @DateFrom, 23), 'All'),
        '; DateTo=', ISNULL(CONVERT(VARCHAR(10), @DateTo, 23), 'All'),
        '; Status=', ISNULL(@Status, 'All'),
        '; Requestor=', ISNULL(CAST(@ScopedRequestorID AS VARCHAR(20)), 'All')
    );

    DECLARE @RowCount INT = 0;

    IF @ReportCode IN ('DEL_AR_REGISTER', 'DEL_ISSUED_COMPLETED', 'DEL_DISCREPANCY_CORRECTION')
    BEGIN
        DECLARE @ARs TABLE
        (
            DeliveryID INT,
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            RequestorName NVARCHAR(200),
            RequestorRole NVARCHAR(100),
            Status VARCHAR(30),
            TotalItems INT,
            TotalQuantity INT,
            GeneratedDate DATETIME2(0),
            IssuedDate DATETIME2(0),
            SignedDate DATETIME2(0),
            IssuedByName NVARCHAR(200),
            SignedByName NVARCHAR(200),
            DiscrepancyNotes NVARCHAR(1000),
            CorrectionNotes NVARCHAR(500),
            CorrectedByName NVARCHAR(200),
            CorrectedAt DATETIME2(0)
        );

        INSERT INTO @ARs
        SELECT
            d.DeliveryID,
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            LTRIM(RTRIM(CONCAT(req.FirstName, ' ', req.LastName))),
            reqRole.RoleName,
            d.Status,
            COUNT(di.DeliveryItemID),
            ISNULL(SUM(di.Quantity), 0),
            d.GeneratedDate,
            d.IssuedDate,
            d.SignedDate,
            CASE WHEN iss.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(iss.FirstName, ' ', iss.LastName))) ELSE N'—' END,
            CASE WHEN sig.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(sig.FirstName, ' ', sig.LastName))) ELSE N'—' END,
            d.DiscrepancyNotes,
            d.CorrectionNotes,
            CASE WHEN cor.UserID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(cor.FirstName, ' ', cor.LastName))) ELSE N'—' END,
            d.CorrectedAt
        FROM dbo.DELIVERIES d
        INNER JOIN dbo.USERS req ON req.UserID = d.RequestorUserID
        INNER JOIN dbo.ROLES reqRole ON reqRole.RoleID = req.RoleID
        LEFT JOIN dbo.USERS iss ON iss.UserID = d.IssuedByUserID
        LEFT JOIN dbo.USERS sig ON sig.UserID = d.SignedByUserID
        LEFT JOIN dbo.USERS cor ON cor.UserID = d.CorrectedByUserID
        LEFT JOIN dbo.DELIVERY_ITEMS di ON di.DeliveryID = d.DeliveryID
        LEFT JOIN dbo.ITEMS i ON i.ItemID = di.ItemID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (NULLIF(@DepartmentRole, N'') IS NULL OR reqRole.RoleName = @DepartmentRole)
          AND (@DateFrom IS NULL OR d.GeneratedDate >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR d.GeneratedDate <= @DateToEnd)
          AND (NULLIF(@Status, '') IS NULL OR d.Status = @Status)
          AND (@ItemID IS NULL OR di.ItemID = @ItemID)
          AND (@CategoryID IS NULL OR i.CategoryID = @CategoryID)
          AND (
              @ReportCode <> 'DEL_ISSUED_COMPLETED'
              OR d.Status IN ('Issued', 'Completed')
          )
          AND (
              @ReportCode <> 'DEL_DISCREPANCY_CORRECTION'
              OR (NULLIF(LTRIM(RTRIM(d.DiscrepancyNotes)), N'') IS NOT NULL OR d.CorrectedAt IS NOT NULL)
          )
        GROUP BY
            d.DeliveryID, d.ARCode, d.RequisitionID,
            req.FirstName, req.LastName, reqRole.RoleName,
            d.Status, d.GeneratedDate, d.IssuedDate, d.SignedDate,
            iss.UserID, iss.FirstName, iss.LastName,
            sig.UserID, sig.FirstName, sig.LastName,
            d.DiscrepancyNotes, d.CorrectionNotes,
            cor.UserID, cor.FirstName, cor.LastName, d.CorrectedAt;

        SELECT @RowCount = COUNT(*) FROM @ARs;

        SELECT
            @RowCount AS TotalARs,
            ISNULL(SUM(TotalQuantity), 0) AS TotalDeliveredUnits,
            ISNULL(SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END), 0) AS CompletedCount,
            ISNULL(SUM(CASE WHEN Status = 'Issued' THEN 1 ELSE 0 END), 0) AS IssuedCount,
            ISNULL(SUM(CASE WHEN NULLIF(LTRIM(RTRIM(DiscrepancyNotes)), N'') IS NOT NULL THEN 1 ELSE 0 END), 0) AS WithDiscrepancyCount
        FROM @ARs;

        SELECT * FROM @ARs ORDER BY GeneratedDate DESC, DeliveryID DESC;
    END
    ELSE IF @ReportCode = 'DEL_SIGNATURE_HISTORY'
    BEGIN
        DECLARE @SigHist TABLE
        (
            ARCode VARCHAR(30),
            RFCode VARCHAR(20),
            Stage VARCHAR(40),
            SignerName NVARCHAR(200),
            SignerRole NVARCHAR(100),
            SignedAt DATETIME2(0),
            Source NVARCHAR(60),
            IntegrityStatus VARCHAR(30)
        );

        INSERT INTO @SigHist
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            h.Stage,
            LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))),
            r.RoleName,
            h.SignedAt,
            N'Delivery History',
            'Archived'
        FROM dbo.DELIVERY_SIGNATURE_HISTORY h
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = h.DeliveryID
        INNER JOIN dbo.USERS u ON u.UserID = h.UserID
        INNER JOIN dbo.ROLES r ON r.RoleID = u.RoleID
        WHERE (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR h.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR h.SignedAt <= @DateToEnd)
        UNION ALL
        SELECT
            d.ARCode,
            'RF-' + RIGHT('0000' + CAST(d.RequisitionID AS VARCHAR(10)), 4),
            ds.Stage,
            ds.SignerName,
            ds.SignerRole,
            ds.SignedAt,
            CASE ds.DocumentType
                WHEN 'ACKNOWLEDGEMENT_RECEIPT' THEN N'Acknowledgement Receipt'
                WHEN 'CORRECTION_REPORT' THEN N'Correction Report'
                ELSE ds.DocumentType
            END,
            CASE
                WHEN ds.IsActive = 0 THEN 'Revoked / Superseded'
                WHEN ds.DocumentHash = dbo.fn_DocumentSignatureHash(ds.DocumentType, ds.DocumentID) THEN 'Verified'
                ELSE 'Hash Mismatch'
            END
        FROM dbo.DOCUMENT_SIGNATURES ds
        INNER JOIN dbo.DELIVERIES d ON d.DeliveryID = ds.DocumentID
        WHERE ds.DocumentType IN ('ACKNOWLEDGEMENT_RECEIPT', 'CORRECTION_REPORT')
          AND (@ScopedRequestorID IS NULL OR d.RequestorUserID = @ScopedRequestorID)
          AND (@DateFrom IS NULL OR ds.SignedAt >= CAST(@DateFrom AS DATETIME2(0)))
          AND (@DateToEnd IS NULL OR ds.SignedAt <= @DateToEnd);

        SELECT @RowCount = COUNT(*) FROM @SigHist;

        SELECT
            @RowCount AS TotalSignatureEvents,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Verified' THEN 1 ELSE 0 END), 0) AS VerifiedCount,
            ISNULL(SUM(CASE WHEN IntegrityStatus = 'Revoked / Superseded' THEN 1 ELSE 0 END), 0) AS RevokedCount
        FROM @SigHist;

        SELECT * FROM @SigHist ORDER BY SignedAt DESC;
    END
    ELSE
        THROW 50809, 'Unknown delivery report code.', 1;

    EXEC dbo.usp_Report_LogAction
        @ActorUserID = @ActorUserID,
        @ReportCode = @ReportCode,
        @ActionType = 'GENERATE',
        @FilterSummary = @FilterDesc,
        @RowCount = @RowCount;
END;
GO
