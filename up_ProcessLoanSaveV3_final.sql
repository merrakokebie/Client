USE [LoanTracking]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
================================================================================
  up_ProcessLoanSaveV3  —  FINAL
  Single-loan fast path for UI save / wire actions
  Replaces: up_ProcessLoanDataV2 in Helper.ProcessLoan (LOAN type only)
  Toggle:   AppSettings["NewProcessDataV3"] = true
================================================================================

  DESIGN DECISIONS (finalised):
  ─────────────────────────────────────────────────────────────────────────────
  @LDP = LastDayProcessed from Originator
    • Used as the calculation date for ALL loans including the one being saved
    • Acts as the consistency anchor — all other loans on the credit line were
      last calculated to this date by the batch SP
    • If we used @TODAY instead, the SUM in Step 11 would be a mixed-date total
      (this loan calculated to today, all others to @LDP) — incorrect
    • If @LDP is from a prior month that is acceptable:
        - Balances will be slightly stale until batch runs tonight
        - This is intentional — forces users to run Process Data to sync
        - UI should show a red alert if LastDayProcessed < today

  Credit line balance strategy:
    • Full SUM across all loans at @LDP — no delta arithmetic
    • We do not need the old loan value before the save
    • db.SaveChanges() already wrote the new values before this SP is called
    • SUM recalculates inline from current Loan table state — always accurate
    • Same approach as the batch SP — proven correct

  Sargable filter:
    • PaydownDate range (> @021_STD_01) instead of YEAR()/MONTH() functions
    • Allows index range seek — critical for large Loan tables

  Single Loan table read:
    • All fields read in one SELECT in Step 2
    • Zero additional reads on Loan — all subsequent steps are pure math

  Excluded from this SP (batch responsibility only):
    • Curtailments   — independent of loan saves
    • LoanHistory    — month-end snapshot only
    • Month-end      — batch only
    • Participation  — pending code review, placeholder in Step 12

================================================================================
*/

CREATE OR ALTER PROCEDURE [dbo].[up_ProcessLoanSaveV3]
(
    @LoanID     int,
    @CLID       int,
    @BrokerID   int,
    @UserName   varchar(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        -- ── Loan fields (all read once in Step 2) ────────────────────────────
        @FundDate               datetime,
        @PaydownDate            datetime,
        @Amount                 money,
        @MortgageAmount         money,
        @ProgramTypeID          int,
        @AdjustmentInterest     money,
        @AdjustmentFee          money,
        @CheckOnlyFee           money,
        @WireFee                money,

        -- ── Credit line fields ────────────────────────────────────────────────
        @P_L                    int,
        @PREM                   money,
        @FLR                    money,
        @CL_Over21Flag          bit,
        @CL_Over21Fee           money,
        @CreditLineBrokerId     int,
        @IsConstSubLimitEnable  bit         = 0,

        -- ── Rate index values ─────────────────────────────────────────────────
        @PLR                    money,      -- Libor
        @FOD                    money,      -- Other
        @FSR                    money,      -- SOFR

        -- ── Computed rate ─────────────────────────────────────────────────────
        @LIR                    money,

        -- ── Date anchors ─────────────────────────────────────────────────────
        @TODAY                  datetime,
        @LDP                    datetime,   -- consistency anchor from Originator
        @LPC                    datetime,
        @021_STD_01             datetime,   -- 1st of @LDP month
        @021_STD                datetime,   -- raw 21-day mark (FundDate + 21)
        @021_STD_Effective      datetime,   -- clamped 21-day mark

        -- ── Per-loan computed values (all scalar, no queries after Step 2) ───
        @L_AMT                  money,      -- active amount (0 if paid down)
        @I_ACR                  money,      -- interest accrued MTD
        @L_INT                  money,      -- daily interest slice
        @D_OUT                  int,        -- days outstanding
        @L21DOUT                int,        -- over-21 days this month
        @L_LOver21Fee           money,      -- total over-21 fee this month
        @L_Over21Fee            money,      -- per-day over-21 rate
        @C_UFEE                 money,      -- total fee bundle

        -- ── Credit line totals (scalar, written by one UPDATE) ───────────────
        @NewBalance             money,
        @NewCL_INT              money,
        @NewI_MTD               money,
        @NewAdjInterestMTD      money,
        @NewConstSubLimit       money,

        -- ── Construction ─────────────────────────────────────────────────────
        @ConstructionProgramType int        = 14,

        -- ── Error ─────────────────────────────────────────────────────────────
        @MSG2LOG                varchar(MAX);

    BEGIN TRY

        -- =====================================================================
        -- STEP 1: Establish @LDP — the consistency anchor
        --
        --  @LDP = LastDayProcessed from Originator.
        --  This is the date ALL loans on this credit line were last calculated
        --  to by the batch SP (up_ProcessAllDataV2).
        --  We MUST use the same date for this loan and the credit line SUM
        --  so that the totals are internally consistent.
        --
        --  If @LDP < today: balances will be slightly behind.
        --  That is intentional — forces users to run Process Data to sync.
        --  UI should show a red alert when LastDayProcessed < today.
        --
        --  Only exception: if @LDP is somehow in the future (should never
        --  happen given UI guard, but belt-and-suspenders clamp here too).
        -- =====================================================================
        SET @TODAY = CONVERT(datetime, CONVERT(varchar, GETDATE(), 101));

        SELECT TOP 1
            @LDP = LastDayProcessed,
            @LPC = LastPeriodClosed
        FROM dbo.Originator WITH (NOLOCK);

        -- Future-date guard only — never override with @TODAY otherwise
        IF @LDP > @TODAY
            SET @LDP = @TODAY;

        -- Month anchor for Over21 clamping and sargable filter
        SET @021_STD_01 = DATEFROMPARTS(YEAR(@LDP), MONTH(@LDP), 1);

        -- =====================================================================
        -- STEP 2: Read the loan — one SELECT, all fields
        --         No further reads on the Loan table after this point
        -- =====================================================================
        SELECT
            @FundDate           = l.FundDate,
            @PaydownDate        = l.PaydownDate,
            @Amount             = l.Amount,
            @MortgageAmount     = l.MortgageAmount,
            @ProgramTypeID      = l.ProgramTypeID,
            @AdjustmentInterest = l.AdjustmentInterest,
            @AdjustmentFee      = l.AdjustmentFee,
            @CheckOnlyFee       = l.CheckOnlyFee,
            @WireFee            = l.WireFee
        FROM dbo.Loan l WITH (NOLOCK)
        WHERE l.LoanID = @LoanID;

        IF @FundDate IS NULL
        BEGIN
            RAISERROR('up_ProcessLoanSaveV3: LoanID %d not found.', 16, 1, @LoanID);
            RETURN -1;
        END

        -- =====================================================================
        -- STEP 3: Read credit line — one SELECT
        -- =====================================================================
        SELECT
            @P_L                = cl.PrimeLIbor,
            @PREM               = cl.PrimePremium,
            @FLR                = cl.RateFloor,
            @CL_Over21Flag      = cl.Over21Flag,
            @CL_Over21Fee       = cl.Over21Fee,
            @CreditLineBrokerId = cl.BrokerID
        FROM dbo.CreditLine cl WITH (NOLOCK)
        WHERE cl.CreditLineID = @CLID;

        -- =====================================================================
        -- STEP 4: Get published rate as of @LDP — one SELECT TOP 1
        -- =====================================================================
        SELECT TOP 1
            @PLR = r.Libor,
            @FOD = r.Other,
            @FSR = r.SOFR
        FROM dbo.Rate r WITH (NOLOCK)
        WHERE r.Date <= @LDP
        ORDER BY r.Date DESC;

        -- =====================================================================
        -- STEP 5: Compute effective interest rate
        -- =====================================================================
        SET @LIR = CASE @P_L
            WHEN 1 THEN @FLR + @PREM    -- Prime
            WHEN 2 THEN @PLR + @PREM    -- Libor
            WHEN 3 THEN @PLR + @PREM    -- Fed Funds
            WHEN 4 THEN @FOD + @PREM    -- Other
            WHEN 5 THEN @FSR + @PREM    -- SOFR
            ELSE        @FLR + @PREM    -- fallback to floor
        END;
        IF @LIR < @FLR SET @LIR = @FLR;

        -- =====================================================================
        -- STEP 6: Construction sub-limit flag from broker — one SELECT
        -- =====================================================================
        IF @CreditLineBrokerId IS NOT NULL
            SELECT @IsConstSubLimitEnable = IsConstSubLimitEnable
            FROM   dbo.Broker WITH (NOLOCK)
            WHERE  BrokerID = @CreditLineBrokerId;

        -- =====================================================================
        -- STEP 7: Active amount and days outstanding
        --         Pure scalar — no queries
        -- =====================================================================
        SET @L_AMT = CASE
            WHEN @PaydownDate IS NULL OR @PaydownDate > @LDP
            THEN @Amount
            ELSE 0.00
        END;

        SET @D_OUT = CASE
            WHEN @PaydownDate IS NULL OR @PaydownDate > @LDP
            THEN DATEDIFF(day, @FundDate, @LDP) + 1
            ELSE DATEDIFF(day, @FundDate, @PaydownDate)
        END;

        -- =====================================================================
        -- STEP 8: MTD interest accrued
        --
        --  Four combinations matching up_ProcessLoans exactly:
        --  active   × funded-this-month  → DATEDIFF(FundDate, @LDP)+1 days
        --  active   × funded-prior-month → DAY(@LDP) days
        --  paiddown × funded-this-month  → DATEDIFF(FundDate, PaydownDate) days
        --  paiddown × funded-prior-month → DAY(PaydownDate)-1 days
        --
        --  All multiplied by @LIR × Amount / 3,600,000
        --  (divisor confirmed from original up_ProcessLoans images)
        -- =====================================================================
        SET @I_ACR = CASE

            WHEN @PaydownDate IS NULL OR @PaydownDate > @LDP THEN
                -- Active loan
                CASE
                    WHEN  YEAR(@FundDate) = YEAR(@LDP)
                      AND MONTH(@FundDate) = MONTH(@LDP)
                    THEN ((DATEDIFF(day, @FundDate, @LDP) + 1) * @LIR * @Amount)
                         / 3600000.00
                    ELSE  (DAY(@LDP) * @LIR * @Amount)
                         / 3600000.00
                END

            ELSE
                -- Paid down this month
                CASE
                    WHEN  YEAR(@FundDate) = YEAR(@LDP)
                      AND MONTH(@FundDate) = MONTH(@LDP)
                    THEN (DATEDIFF(day, @FundDate, @PaydownDate) * @LIR * @Amount)
                         / 3600000.00
                    ELSE ((DAY(@PaydownDate) - 1) * @LIR * @Amount)
                         / 3600000.00
                END
        END;

        SET @L_INT = CASE
            WHEN @L_AMT > 0
            THEN (@Amount * @LIR) / 3600000.00
            ELSE 0.00
        END;

        -- =====================================================================
        -- STEP 9: Over21 fee
        --         Pure scalar — no queries
        --         All fee fields already in memory from Step 2
        --
        --  Logic:
        --  1. Only when @CL_Over21Flag = 1 AND loan is active (@L_AMT > 0)
        --     AND loan is more than 21 days old
        --  2. Raw threshold = FundDate + 21
        --  3. Clamp to @021_STD_01 if threshold fell in a prior month
        --     → prevents re-billing days already charged last month
        --  4. Fee = days past threshold this month × @CL_Over21Fee
        -- =====================================================================
        SET @L21DOUT      = 0;
        SET @L_LOver21Fee = 0.00;
        SET @L_Over21Fee  = 0.00;

        IF @CL_Over21Flag = 1
           AND @L_AMT     > 0       -- active loan only
           AND @D_OUT     > 21      -- past 21-day grace period
        BEGIN
            SET @021_STD = DATEADD(day, 21, @FundDate);

            IF @021_STD <= @LDP
            BEGIN
                -- Clamp: threshold in prior month → reset to month start
                -- Threshold in current month     → use as-is
                SET @021_STD_Effective = CASE
                    WHEN @021_STD <= @021_STD_01
                    THEN @021_STD_01
                    ELSE @021_STD
                END;

                SET @L21DOUT      = DATEDIFF(day, @021_STD_Effective, @LDP) + 1;
                SET @L_LOver21Fee = @L21DOUT * @CL_Over21Fee;
                SET @L_Over21Fee  = @CL_Over21Fee;
            END
        END

        -- Total fee bundle — all values already in memory, zero queries
        SET @C_UFEE = ISNULL(@CheckOnlyFee, 0.00)
                    + ISNULL(@WireFee,       0.00)
                    + ISNULL(@AdjustmentFee, 0.00)
                    + @L_LOver21Fee;

        -- =====================================================================
        -- STEP 10: Update THIS loan row
        --          Single UPDATE covering both Over21 and non-Over21 cases
        -- =====================================================================
        UPDATE dbo.Loan
        SET
            LastInterest            = @L_INT,
            LastInterestUpdateDate  = @LDP,
            DaysOutstanding         = @D_OUT,
            InterestAccrued         = @I_ACR,
            LastModifiedBy          = ISNULL(@UserName, 'Operation'),
            -- Over21 fields: only overwrite when Over21 fired
            -- Preserve existing values when loan is inside 21-day window
            LastOver21Fee   = CASE WHEN @L21DOUT > 0
                                   THEN @L_LOver21Fee ELSE LastOver21Fee END,
            Over21Fee       = CASE WHEN @L21DOUT > 0
                                   THEN @L_Over21Fee  ELSE Over21Fee     END,
            CheckFee        = CASE WHEN @L21DOUT > 0
                                   THEN @C_UFEE       ELSE CheckFee      END
        WHERE LoanID = @LoanID;

        -- =====================================================================
        -- STEP 11: Recalculate CreditLine totals — one SUM query
        --
        --  WHY SUM ACROSS ALL LOANS (not delta):
        --  db.SaveChanges() has already written the new loan values before
        --  this SP is called. The old loan amount is gone — we cannot do
        --  delta arithmetic. A full SUM is the only correct approach.
        --  It also eliminates any risk of accumulated drift over time.
        --  This is the same approach the batch SP uses.
        --
        --  WHY @LDP NOT @TODAY:
        --  All other loans on this credit line were last calculated to @LDP
        --  by the batch SP. Using @TODAY for this loan but @LDP for others
        --  would produce a mixed-date total. @LDP keeps everything consistent.
        --  If @LDP < today the balances are slightly stale — intentional.
        --  UI should show a red alert prompting user to run Process Data.
        --
        --  SARGABLE FILTER (FIX 1):
        --  PaydownDate > @021_STD_01 replaces YEAR()/MONTH() function calls
        --  Allows index range seek instead of full table scan
        --  Logically equivalent: loans paid down before this month start
        --  have zero contribution to this month's totals
        -- =====================================================================
        SELECT
            @NewBalance =
                ISNULL(SUM(
                    CASE WHEN l.PaydownDate IS NULL OR l.PaydownDate > @LDP
                         THEN l.Amount
                         ELSE 0.00 END
                ), 0.00),

            @NewCL_INT =
                ISNULL(SUM(
                    CASE WHEN l.PaydownDate IS NULL OR l.PaydownDate > @LDP
                         THEN (l.Amount * @LIR) / 3600000.00
                         ELSE 0.00 END
                ), 0.00),

            @NewI_MTD =
                ISNULL(SUM(
                    CASE
                        WHEN l.PaydownDate IS NULL OR l.PaydownDate > @LDP THEN
                            CASE
                                WHEN  YEAR(l.FundDate) = YEAR(@LDP)
                                  AND MONTH(l.FundDate) = MONTH(@LDP)
                                THEN ((DATEDIFF(day, l.FundDate, @LDP) + 1)
                                      * @LIR * l.Amount) / 3600000.00
                                ELSE  (DAY(@LDP) * @LIR * l.Amount)
                                      / 3600000.00
                            END
                        ELSE
                            CASE
                                WHEN  YEAR(l.FundDate) = YEAR(@LDP)
                                  AND MONTH(l.FundDate) = MONTH(@LDP)
                                THEN (DATEDIFF(day, l.FundDate, l.PaydownDate)
                                      * @LIR * l.Amount) / 3600000.00
                                ELSE ((DAY(l.PaydownDate) - 1)
                                      * @LIR * l.Amount) / 3600000.00
                            END
                    END
                ), 0.00),

            @NewAdjInterestMTD =
                ISNULL(SUM(ISNULL(l.AdjustmentInterest, 0.00)), 0.00)

        FROM dbo.Loan l WITH (NOLOCK)
        WHERE l.CreditLineID  = @CLID
          AND l.IsCollateral  = 0
          AND l.IsInactive    = 0
          AND l.FundDate     <= @LDP
          AND
          (
              l.PaydownDate IS NULL           -- active, no paydown date
           OR l.PaydownDate  > @LDP           -- active, paid down after LDP
           OR l.PaydownDate  > @021_STD_01    -- paid down this month (sargable)
          );

        -- Single clean UPDATE from scalar variables
        UPDATE dbo.CreditLine
        SET
            Balance               = @NewBalance,
            LastInterest          = @NewCL_INT,
            InterestMtd           = @NewI_MTD,
            AdjustmentInterestMtd = @NewAdjInterestMTD,
            Rate                  = @LIR
        WHERE CreditLineID = @CLID;

        -- =====================================================================
        -- STEP 12: Construction sub-limit
        --          ConstSubLimitUnused = total mortgage commitment
        --                               minus total active construction balance
        --          Only when IsConstSubLimitEnable = 1 on broker
        -- =====================================================================
        IF @IsConstSubLimitEnable = 1
        BEGIN
            SELECT
                @NewConstSubLimit =
                    ISNULL(SUM(l.MortgageAmount), 0.00)
                    - ISNULL(SUM(
                        CASE WHEN l.PaydownDate IS NULL OR l.PaydownDate > @LDP
                             THEN l.Amount ELSE 0.00 END
                    ), 0.00)
            FROM dbo.Loan l WITH (NOLOCK)
            WHERE l.CreditLineID  = @CLID
              AND l.IsCollateral  = 0
              AND l.IsInactive    = 0
              AND l.ProgramTypeID = @ConstructionProgramType
              AND (l.PaydownDate IS NULL OR l.PaydownDate > @LDP);

            UPDATE dbo.CreditLine
            SET    ConstSubLimitUnused = @NewConstSubLimit
            WHERE  CreditLineID = @CLID;
        END

        -- =====================================================================
        -- STEP 13: Participation — placeholder pending code review
        --          Will upsert @LDP participation record only (not a loop)
        --          CurtailmentBalance passed as 0 — curtailments not
        --          recalculated on loan save (batch responsibility)
        -- =====================================================================
        -- TODO: EXECUTE dbo.up_ProcessParticipationV3
        --           @LDP, @CLID, @LIR, @NewBalance,
        --           0.00,   -- CurtailmentBalance: batch only
        --           0.00,   -- CurtailmentInterest: batch only
        --           @UserName;

        RETURN 0;

    END TRY
    BEGIN CATCH
        DECLARE
            @EN  int            = ERROR_NUMBER(),
            @EL  int            = ERROR_LINE(),
            @EP  nvarchar(128)  = ERROR_PROCEDURE(),
            @EM  nvarchar(4000) = ERROR_MESSAGE();

        SET @MSG2LOG =
            'up_ProcessLoanSaveV3 ERROR'
            + CHAR(13) + 'LoanID      : ' + CONVERT(nvarchar(10), @LoanID)
            + CHAR(13) + 'CreditLineID: ' + CONVERT(nvarchar(10), @CLID)
            + CHAR(13) + 'ERROR #     : ' + CONVERT(nvarchar(10), @EN)
            + CHAR(13) + 'PROCEDURE   : ' + ISNULL(@EP, 'N/A')
            + CHAR(13) + 'LINE        : ' + CONVERT(nvarchar(10), @EL)
            + CHAR(13) + 'MESSAGE     : ' + @EM;

        INSERT INTO [dbo].[ProcessLog]
            ([IDName],[LDP],[TD],[LPC],[Message],[CreatedDate],[CreatedBy],[IsErrorLog])
        VALUES
            ('up_ProcessLoanSaveV3', @LDP, @TODAY, @LPC,
             @MSG2LOG, GETDATE(), @UserName, 1);

        RAISERROR(@MSG2LOG, 16, 1);
        RETURN -1;
    END CATCH;
END
GO

/*
================================================================================
  REQUIRED INDEX
  Run once after deployment — critical for Step 11 performance
================================================================================

CREATE INDEX IX_Loan_CreditLine_Save
    ON dbo.Loan
    (
        CreditLineID,   -- equality
        IsCollateral,   -- equality
        IsInactive,     -- equality
        FundDate,       -- range <=
        PaydownDate     -- range IS NULL / > date
    )
    INCLUDE
    (
        Amount,
        MortgageAmount,
        ProgramTypeID,
        AdjustmentInterest,
        CheckFee,
        CheckOnlyFee,
        WireFee,
        AdjustmentFee,
        Over21Fee,
        LastOver21Fee
    );

================================================================================
  QUERY SUMMARY — 6 reads + 2 writes regardless of loan count
================================================================================

  Step 1  SELECT Originator               1 read
  Step 2  SELECT Loan (this loan only)    1 read   all fields, no second read
  Step 3  SELECT CreditLine               1 read
  Step 4  SELECT Rate TOP 1               1 read
  Step 6  SELECT Broker                   1 read   (conditional)
  Step 10 UPDATE Loan                     1 write  (this loan only)
  Step 11 SELECT SUM all loans            1 read   (index seek with covering index)
          UPDATE CreditLine               1 write
  Step 12 SELECT/UPDATE construction      1 read + 1 write (conditional)

  Steps 7,8,9 = pure scalar math, zero database calls

  Compare to old path (25 loans, 15 days into month):
    OLD: ~375 loop iterations across ProcessCurtailments,
         ProcessLoans, ProcessParticipation
    NEW: 6-8 database calls total

================================================================================
  C# INTEGRATION
================================================================================

  Web.config:
    <add key="NewProcessDataV3" value="false" />

  Helper.ProcessLoan:

    bool NewProcessDataV3 = Convert.ToBoolean(
        ConfigurationManager.AppSettings["NewProcessDataV3"].ToString());

    if (autoProcessingType == AutoProcessingType.LOAN)
    {
        if (NewProcessDataV3)
            db.up_ProcessLoanSaveV3(loanId, creditLineId, brokerId, currentUser);
        else if (NewProcessData)
            db.up_ProcessLoanDataV2(1, brokerId, creditLineId, currentUser, loanId);
        else
            db.up_ProcessLoanData(1, brokerId, creditLineId, currentUser, loanId);
    }

    // CREDITLINE type unchanged — stays on V2 (legitimate full recalc)
    if (autoProcessingType == AutoProcessingType.CREDITLINE)
    {
        var resp = (NewProcessData)
            ? db.up_ProcessLoanDataV2(1, brokerId, creditLineId, currentUser, 0)
            : db.up_ProcessLoanData(1, brokerId, creditLineId, currentUser, 0);
    }

================================================================================
*/
