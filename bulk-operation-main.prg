//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Bulk Operation Preparation Agent -- driver program.
///
/// Demonstrates natural-language bulk database update preparation over
/// the Northwind PostgreSQL database using an FSM agent.
///
/// For each task the agent:
///   1. Queries the live database to identify the affected rows (LLM + tool)
///   2. Computes the exact new values as specified
///   3. Shows a reviewable change table (up to 10 rows) via ApprovalTool
///   4. Waits for the user to choose:
///        Y  approve  -> writes a transaction-wrapped .sql file to disk
///        R  reject   -> re-analyzes with the correction feedback (up to 3 retries)
///        A  abort    -> skips this task and continues with the next one
///
/// Five example tasks exercise different kinds of bulk operations:
///
///   T1 -- price increase, top-N by sales, percentage + rounding
///   T2 -- discontinue products with no order history, supplier filter
///   T3 -- price reduction by category, percentage + rounding
///   T4 -- stock increase for low-inventory products
///   T5 -- flat price override by current price range and supplier
///
/// Flow per task:
///   RunTask() creates a fresh AgentContext, places the request on the
///   blackboard, fires AgentStateMachine:run(), and reports the outcome.
///   The loop in Main() always advances to the next task regardless of
///   whether the previous one was approved, aborted, or exhausted.
///
/// Requires:
///   ANTHROPIC_API_KEY set in the environment (or apikey.bat sourced). If
///   not provided falls back to Alaska Software free of charge LLM-Router
///   (requires valid Xbase++ V3 License).
///   PostgreSQL Northwind database on localhost (configure cConnect below)
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"
#include "dac.ch"
#include "pgdbe.ch"

PROCEDURE Main()
   LOCAL cConnect
   LOCAL oSession
   LOCAL oAgent
   LOCAL aTasks
   LOCAL cSep
   LOCAL nI

   SET CHARSET TO ANSI

   cSep := Replicate( "=", 72 )

   // -----------------------------------------------------------------------
   // PostgreSQL connection
   // -----------------------------------------------------------------------
   DbeLoad( "PGDBE" )
   DbeSetDefault( "PGDBE" )

   cConnect := "DBE=pgdbe;SERVER=localhost;DB=northwind;UID=postgres;PWD=postgres"
   oSession  := DacSession():New( cConnect )

   IF !oSession:isConnected()
      ? "Connection failed:", oSession:getLastMessage()
      RETURN
   ENDIF
   ? "Connected to Northwind Traders database."
   ?

   // -----------------------------------------------------------------------
   // Token usage observer -- prints LLM cost per analyze call.
   // ToolAwareSender accumulates tokens across all tool-calling rounds so
   // the count shown reflects the full multi-round cost per state execution.
   // -----------------------------------------------------------------------
   LLMService():onUsage( ;
      {|oAgt, cModel, nIn, nOut, cTS, nElapsedInMS| ;
         Qout( "    [" + cModel + ;
               "  in:"  + AllTrim( Str( nIn  ) ) + ;
               " out:"  + AllTrim( Str( nOut ) ) + " tokens" + ;
               "  " + AllTrim( Str( nElapsedInMS ) ) + " ms]" ) } )

   // -----------------------------------------------------------------------
   // Build the agent once -- it is reused for all tasks.
   // The NorthwindBulkQueryTool inside holds only the DacSession reference,
   // which is safely shared across sequential runs.
   // -----------------------------------------------------------------------
   oAgent := BulkOperationAgent():New( oSession )

   // -----------------------------------------------------------------------
   // Five bulk operation tasks.
   //
   // T1  Top-5 price increase by 2025 sales volume, percentage + rounding
   // T2  Discontinue supplier-3 products with no order history at all
   // T3  15% price reduction for the Seafood category, 2 decimal places
   // T4  Stock boost for the 5 lowest-stocked active products
   // T5  Flat price override for products in a price band from supplier 1
   //
   // Change #if 0 to #if 1 below to run the German task descriptions instead.
   // -----------------------------------------------------------------------
   aTasks := {}

   #if 1
   // ---- German task descriptions -----------------------------------------

   // T1 -- Preiserhoehung, Top-5 nach Umsatz 2025, Rundung auf 0.50
   AAdd( aTasks, ;
      "Erhoehe den Stueckpreis der 5 umsatzstaerksten Produkte nach Erloesen " + ;
      "im Jahr 2025 um 10 %. Runde jeden neuen Preis auf den naechsten $0,50." )

   // T2 -- Produkte ohne Bestellhistorie einstellen, gefiltert nach Lieferant
   AAdd( aTasks, ;
      "Markiere alle Produkte von Lieferant-ID 3 als eingestellt " + ;
      "(setze discontinued = 1), die noch nie in einer Bestellung " + ;
      "in der gesamten Bestellhistorie aufgetaucht sind." )

   // T3 -- Kategorie-weite Preissenkung mit Dezimalrundung
   AAdd( aTasks, ;
      "Reduziere den Stueckpreis aller Produkte der Kategorie Seafood " + ;
      "um 15 %. Runde jeden neuen Preis auf genau 2 Dezimalstellen." )

   // T4 -- Lagerauffuellung fuer die 5 am wenigsten bevorrrateten Produkte
   AAdd( aTasks, ;
      "Erhoehe den unitsinstock der 5 Produkte mit dem niedrigsten " + ;
      "aktuellen Lagerbestand, die nicht eingestellt sind " + ;
      "(discontinued = 0), jeweils um 100 Einheiten." )

   // T5 -- Pauschale Preisanpassung innerhalb einer Preisspanne von Lieferant 1
   AAdd( aTasks, ;
      "Setze unitprice = 9.99 fuer alle Produkte von Lieferant-ID 1, " + ;
      "deren aktueller unitprice zwischen 10.00 und 12.00 liegt " + ;
      "(beide Grenzen einschliesslich)." )

   #else
   // ---- English task descriptions (default) ------------------------------

   // T1 -- price increase, top-N by 2025 revenue, rounding to nearest 0.50
   AAdd( aTasks, ;
      "Increase the unit price of the top 5 best-selling products by revenue " + ;
      "in 2025 by 10%. Round each new price to the nearest $0.50." )

   // T2 -- discontinue products with no order history, filtered by supplier
   AAdd( aTasks, ;
      "Mark as discontinued (set discontinued = 1) all products supplied " + ;
      "by supplier ID 3 that have never appeared in any order " + ;
      "in the entire order history." )

   // T3 -- category-wide price reduction with decimal rounding
   AAdd( aTasks, ;
      "Reduce the unit price of every product in the Seafood category " + ;
      "by 15%. Round each new price to exactly 2 decimal places." )

   // T4 -- stock increase for the most understocked active products
   AAdd( aTasks, ;
      "Add 100 units to the unitsinstock of the 5 products with the " + ;
      "lowest current stock that are not discontinued (discontinued = 0)." )

   // T5 -- flat price override within a price band from a specific supplier
   AAdd( aTasks, ;
      "Set unitprice = 9.99 for all products from supplier ID 1 " + ;
      "whose current unitprice is between 10.00 and 12.00 inclusive." )

   #endif

   // -----------------------------------------------------------------------
   // Run each task interactively.
   // The loop always advances -- aborted and failed tasks are reported but
   // do not stop the remaining tasks from running.
   // -----------------------------------------------------------------------
   FOR nI := 1 TO Len( aTasks )
      ?
      ? cSep
      ? "Task " + AllTrim( Str( nI ) ) + " of " + AllTrim( Str( Len( aTasks ) ) )
      ? cSep
      ? aTasks[nI]
      ? Replicate( "-", 72 )

      RunTask( oAgent, aTasks[nI] )
   NEXT

   ?
   ? cSep
   ? "All tasks processed."

   oSession:disconnect()

RETURN


// ---------------------------------------------------------------------------
// RunTask
//
// Executes one bulk operation request through the BulkOperationAgent FSM.
// Creates a fresh AgentContext so each task starts with an empty blackboard
// and clean visit counts. Reports the outcome and returns so the caller
// can continue with the next task regardless of the terminal state.
// ---------------------------------------------------------------------------

PROCEDURE RunTask( oAgent, cTask )
   LOCAL oCtx      := AgentContext():New()
   LOCAL oMachine
   LOCAL oLastEntry
   LOCAL cTerminal
   LOCAL oErr

   oCtx:set( "request", cTask )

   BEGIN SEQUENCE

      oMachine := AgentStateMachine():forAgent( oAgent )
      oMachine:run( oCtx )

      oLastEntry := oMachine:getTrace()[ Len( oMachine:getTrace() ) ]
      cTerminal  := oLastEntry:getName()

      DO CASE
      CASE cTerminal == "write_sql"
         DisplayWriteResult( oCtx:get( "result" ) )

      CASE cTerminal == "aborted"
         ?
         ? "  Task aborted by user."

      OTHERWISE
         ?
         ? "  Task ended at '" + cTerminal + "' -- no SQL written " + ;
           "after " + AllTrim( Str( oAgent:getMaxAttempts() ) ) + " attempt(s)."
      ENDCASE

   RECOVER USING oErr
      ?
      ? "  Error: " + oErr:description
   END SEQUENCE

RETURN


// ---------------------------------------------------------------------------
// DisplayWriteResult
//
// Prints a short success summary after the SQL file has been written.
// ---------------------------------------------------------------------------

PROCEDURE DisplayWriteResult( oResult )
   LOCAL cSep

   cSep := Replicate( "-", 72 )

   ?
   ? cSep
   ? "  SQL file written successfully"
   ? cSep
   ? "  File      : " + oResult:filePath
   ? "  Statements: " + AllTrim( Str( oResult:statementCount ) )
   ? "  " + oResult:message
   ? cSep

RETURN
