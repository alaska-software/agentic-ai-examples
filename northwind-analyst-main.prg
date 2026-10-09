//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Northwind Business Analyst Agent -- driver program.
///
/// Demonstrates natural-language business analysis over a PostgreSQL
/// Northwind database using a single PromptRunner with a SQL tool.
/// Five complex business questions are posed; each answer consists of:
///   - a text summary produced by the LLM
///   - one or more data tables collected from NorthwindQueryTool
///
/// The LLM calls ExecuteQuery() autonomously (one or more times per
/// question) to retrieve the data it needs.  ToolAwareSender drives the
/// multi-round SSE loop transparently; GenerateText() returns only after
/// the model has emitted its final text answer.
///
/// Flow per question:
///   Main resets oTool:results
///   oRunner:generateText( cQuestion )
///     -> LLM calls ExecuteQuery N times via ToolAwareSender
///           -> NorthwindQueryTool stores QueryResult objects in ::results
///     -> LLM emits final text answer
///   DisplayAnswer prints text + all accumulated tables
///
/// Usage:  northwind-analyst.exe [config-file]
///         (config-file defaults to northwind-analyst-questions-en.config in
///         the cwd; pass northwind-analyst-questions-de.config for the
///         German sample questions)
///
/// Requires:
///   ANTHROPIC_API_KEY set in the environment. If not provided falls back
///   to Alaska Software free of charge LLM-Router (requires valid
///   Xbase++ V3 License).
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

PROCEDURE Main( cConfigFile )
   LOCAL cConnect
   LOCAL oSession
   LOCAL oTool
   LOCAL oRunner
   LOCAL aQuestions
   LOCAL cAnswer
   LOCAL nI
   LOCAL cSep
   LOCAL oError

   DEFAULT cConfigFile TO "northwind-analyst-questions-en.config"
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
   // Token usage observer -- prints LLM cost per call to the console.
   // ToolAwareSender accumulates tokens across all tool-calling rounds so
   // the count shown here reflects the full multi-round cost per question.
   // -----------------------------------------------------------------------
   LLMService():onUsage( ;
      {|oAgt, cModel, nIn, nOut, cTS, nElapsedInMS| ;
         Qout( "    [" + cModel + ;
           "  in:" + AllTrim( Str( nIn  ) ) + ;
           " out:" + AllTrim( Str( nOut ) ) + " tokens" + ;
           "  " + AllTrim( Str( nElapsedInMS ) ) + " ms]") }  )

   // -----------------------------------------------------------------------
   // Build the tool once; its ::results array is reset before each question.
   // -----------------------------------------------------------------------
   oTool := NorthwindQueryTool():New( oSession )

   // -----------------------------------------------------------------------
   // Build the base PromptRunner (immutable -- reused for all questions).
   //
   // Three system-prompt layers:
   //   1. NorthwindPersonas:analyst()    -- role, goal, backstory
   //   2. NorthwindSchemaContributor     -- table definitions + revenue formula
   //   3. Rules instruction              -- behavioural constraints
   //
   // Temperature 0 for consistent, deterministic SQL generation.
   // -----------------------------------------------------------------------
   oRunner := PromptRunner():New() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ) ;
                                     :withTemperature( 0 ) ) ;
              :withPromptContributor( NorthwindPersonas():analyst() ) ;
              :withPromptContributor( NorthwindSchemaContributor():New() ) ;
              :withSystemPrompt( ;
                 "Rules:" + CRLF + ;
                 "  1. Use the ExecuteQuery tool for every data lookup. Never guess values." + CRLF + ;
                 "  2. You may call ExecuteQuery multiple times if the question requires it." + CRLF + ;
                 "  3. Give each result table a short, descriptive title." + CRLF + ;
                 "  4. Begin your text answer with a one-sentence executive summary." + CRLF + ;
                 "  5. Cite the key numbers explicitly in your text answer." + CRLF + ;
                 "  6. Do not reproduce the full table data in your text -- tables are shown separately." + CRLF + ;
                 "  7. The database driver treats :: as a named parameter marker (e.g. ::tablename)." + CRLF + ;
                 "     Escape the PostgreSQL cast operator with a backslash: write \:: instead of ::." + CRLF + ;
                 "     Wrong: SUM(...)::NUMERIC      Right: SUM(...)\::NUMERIC" + CRLF + ;
                 "     CAST(SUM(...) AS NUMERIC) is an equivalent alternative that needs no escaping." + CRLF + ;
                 "  8. CTEs are fully supported: WITH name AS (SELECT ...) SELECT ..." + CRLF + ;
                 "     Use CTEs freely for multi-step calculations instead of nested subqueries." + CRLF + ;
                 "  9. Time-period labels (quarters, months, years) must always be expressed as" + CRLF + ;
                 "     labelled strings, not bare numbers. DATE_PART and EXTRACT return" + CRLF + ;
                 "     double precision which the database driver cannot propagate through" + CRLF + ;
                 "     the result workarea. Always cast and prefix:" + CRLF + ;
                 "     Wrong: EXTRACT(QUARTER FROM orderdate) AS quartal" + CRLF + ;
                 "     Right: 'Q' || EXTRACT(QUARTER FROM orderdate)\::INT AS quartal" ) ;
              :withTool( oTool )

   // -----------------------------------------------------------------------
   // Five complex business questions designed to exercise:
   //   Q1 -- CTE + multi-table JOIN + aggregation + percentage of total
   //   Q2 -- date grouping + conditional aggregation + YoY growth %
   //   Q3 -- HAVING filter + subquery for average comparison
   //   Q4 -- multi-level aggregation + per-employee top-category lookup
   //   Q5 -- YoY H1 conditional aggregation + decline filter + sort
   //
   // Data spans 2024 - June 2026. 2025 is used as the reference full year;
   // Q2 compares 2024 vs 2025; Q5 compares H1 2025 vs H1 2026.
   //
   // Loaded from an XML config file (DE/EN config-file pattern - see
   // support-triage-agent-common.prg / LoadInboundMessages() for the
   // reference implementation this mirrors).
   // -----------------------------------------------------------------------
   aQuestions := LoadQuestions( cConfigFile )

   IF Empty( aQuestions )
      ? "No questions loaded from", cConfigFile
      oSession:disconnect()
      RETURN
   ENDIF

   // -----------------------------------------------------------------------
   // Run each question
   // -----------------------------------------------------------------------
   FOR nI := 1 TO Len( aQuestions )
      ?
      ? cSep
      ? "Question " + AllTrim( Str( nI ) ) + " of " + AllTrim( Str( Len( aQuestions ) ) )
      ? cSep
      ? aQuestions[nI]
      ? Replicate( "-", 72 )

      oTool:results := {}      // reset the table accumulator for this question

      BEGIN SEQUENCE
         cAnswer := oRunner:generateText( aQuestions[nI] )
         IF cAnswer == NIL
            ? "LLM call failed:", oRunner:getLastError()
         ELSE
            DisplayAnswer( cAnswer, oTool:results )
         ENDIF
      RECOVER USING oError
         ? "Error:", oError:description
      END SEQUENCE
   NEXT

   ?
   ? cSep
   ? "Done."
   oSession:disconnect()

RETURN


// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

/// <summary>
/// Print the LLM text answer followed by each data table.
/// </summary>
///
PROCEDURE DisplayAnswer( cAnswer, aResults )
   LOCAL nI

   ?
   ? "[Answer]"
   // The SSE client applies Char2UTF8 before JSON parsing, so the accumulated
   // text arrives as single-encoded UTF-8 bytes stored in an ANSI string.
   // ToolAwareSender unwraps one layer; one layer remains here -- unwrap it.
   ? UTF82Char( cAnswer )

   FOR nI := 1 TO Len( aResults )
      DisplayTable( aResults[nI] )
   NEXT

RETURN


/// <summary>
/// Print one QueryResult as a formatted console table.
/// Column widths are computed from the header and data values, capped at 30.
/// </summary>
///
PROCEDURE DisplayTable( oTable )
   LOCAL nCols
   LOCAL nRows
   LOCAL aWidths
   LOCAL nF
   LOCAL nRow
   LOCAL cLine
   LOCAL cBorder
   LOCAL cVal

   IF Empty( oTable:columns )
      RETURN
   ENDIF

   nCols := Len( oTable:columns )
   nRows := Len( oTable:rows )

   // Compute per-column display width: max(header length, longest value), capped at 30
   aWidths := {}
   FOR nF := 1 TO nCols
      AAdd( aWidths, Min( 30, Len( oTable:columns[nF] ) ) )
   NEXT
   FOR nRow := 1 TO nRows
      FOR nF := 1 TO nCols
         cVal        := Left( FormatFieldValue( oTable:rows[nRow][nF] ), 30 )
         aWidths[nF] := Max( aWidths[nF], Len( cVal ) )
      NEXT
   NEXT

   // Table heading
   ?
   ? "[" + oTable:title + "]"

   // Top border
   cBorder := "+"
   FOR nF := 1 TO nCols
      cBorder += Replicate( "-", aWidths[nF] + 2 ) + "+"
   NEXT
   ? cBorder

   // Header row
   cLine := "|"
   FOR nF := 1 TO nCols
      cLine += " " + PadR( Left( oTable:columns[nF], aWidths[nF] ), aWidths[nF] ) + " |"
   NEXT
   ? cLine
   ? cBorder

   // Data rows
   FOR nRow := 1 TO nRows
      cLine := "|"
      FOR nF := 1 TO nCols
         cVal  := Left( FormatFieldValue( oTable:rows[nRow][nF] ), aWidths[nF] )
         cLine += " " + PadR( cVal, aWidths[nF] ) + " |"
      NEXT
      ? cLine
   NEXT

   // Bottom border and row count
   ? cBorder
   ? "  " + AllTrim( Str( nRows ) ) + " row(s)"

RETURN


/// <summary>
/// Convert a field value of any Xbase++ type to a printable string.
/// Numbers with a fractional part are formatted to 2 decimal places.
/// </summary>
///
FUNCTION FormatFieldValue( xVal )
   LOCAL cType
   LOCAL cMemo
   LOCAL nMemo

   IF xVal == NIL
      RETURN "(null)"
   ENDIF

   cType := ValType( xVal )

   DO CASE
   CASE cType == "C"
      RETURN AllTrim( xVal )
   CASE cType == "N"
      IF Int( xVal ) == xVal
         RETURN AllTrim( Str( xVal, 18, 0 ) )
      ENDIF
      RETURN AllTrim( Str( xVal, 18, 2 ) )
   CASE cType == "D"
      RETURN DToC( xVal )
   CASE cType == "L"
      RETURN If( xVal, "true", "false" )
   CASE cType == "M"
      // PGDBE maps PostgreSQL double precision (DATE_PART / EXTRACT result)
      // to a Xbase++ memo field.  The memo content is the text representation
      // of the numeric value, e.g. "1.000000" for quarter 1.
      // When Val() returns non-zero the content is numeric; display it as an
      // integer or decimal.  For non-numeric memo text (e.g. "Q1") fall
      // through and return the text as-is.
      cMemo := AllTrim( xVal )
      nMemo := Val( cMemo )
      IF nMemo != 0
         IF Int( nMemo ) == nMemo
            RETURN AllTrim( Str( nMemo, 18, 0 ) )
         ENDIF
         RETURN AllTrim( Str( nMemo, 18, 2 ) )
      ENDIF
      RETURN cMemo
   CASE cType == "O"
      RETURN Var2Json( xVal )
   CASE cType == "A"
      RETURN Var2Json( xVal )
   ENDCASE

   // Fallback for any remaining PGDBE-specific type code.
   RETURN "(" + cType + ")"
